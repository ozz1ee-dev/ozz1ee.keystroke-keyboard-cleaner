#!/usr/bin/env python3
"""Grab every keyboard and pointing device for the requested duration.

Reads /proc/bus/input/devices, opens matching /dev/input/event* nodes and
issues EVIOCGRAB so the kernel stops delivering their events until the
timeout expires. Releases every grabbed device on exit, signal, or fatal
error so the keyboard always comes back even on crashes.

Output is plain text intended for an interactive terminal. The launcher
dispatches this helper through xdg-terminal-exec so the Omalaunch UI can
close immediately while the cleaning window stays on screen.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

# EVIOCGRAB on Linux/amd64: _IOW('E', 0x10, 4) -> 0x40044590.
# The size (sizeof int) is the same on every 64-bit Linux ABI we target.
EVIOCGRAB = 0x40044590

EV_KEY = 1
EV_REL = 2
EV_ABS = 3
EV_MSC = 4
EV_SW = 5
EV_LED = 0x11
EV_SND = 0x12
EV_REP = 0x14
EV_FF = 0x15
EV_PWR = 0x16

# KEY bit positions (input-event-codes.h) are not referenced by name any
# more: the classifier counts set bits rather than probing individual
# positions (see `categorize()` below). Constants are kept off this list
# on purpose — adding them back invites future bugs like the
# `key >> KEY_KPENTER and key >> KEY_KPENTER` check that mistook the
# Apple SMC power/lid device for a keyboard in v0.2.0.

# A real keyboard lights up dozens of KEY bits across the letter, modifier,
# function-key, and keypad ranges. Single-button devices (power button, lid
# switch, headphone jack, headset volume keys) usually expose one or two
# bits. The threshold below sits between those two populations so the
# classifier can distinguish them without enumerating every keycode.
#
# 8 bits is conservative: a power button exposes exactly 1 (KEY_POWER=116),
# a headset volume rocker exposes 2-3 (KEY_VOLUMEUP=115, KEY_VOLUMEDOWN=114,
# KEY_MUTE=113), and even a tiny keypad-only device exposes at least the
# keypad arrows + digits (>=10 bits). Real keyboards expose 100+ bits.
MIN_KEYBOARD_KEY_POPCOUNT = 8

INPUT_DEVICES_PATH = Path("/proc/bus/input/devices")
INPUT_EVENT_ROOT = Path("/dev/input")

MIN_DURATION = 1
MAX_DURATION = 60 * 60

# PUA codepoint for nf-md-keyboard — matches the launcher icon so the pop-up and the
# extension shortcut read as the same action. Stays a plain string so the rest of the
# script never has to care about encoding.
KEYBOARD_GLYPH = "\U000F0313"

# Omarchy ships a notification wrapper at this fixed path that talks to Quickshell's
# org.freedesktop.Notifications over busctl. Treating it as optional keeps the grab/
# release logic identical for non-Omarchy installs.
OMARCHY_NOTIFY = Path("/usr/share/omarchy/bin/omarchy-notification-send")
OMARCHY_NOTIFY_AVAILABLE = OMARCHY_NOTIFY.is_file()


def parse_keyword(tokens: list[str]) -> int:
    """Combine the whitespace-separated hex tokens of a `B: KEY=...` line
    from /proc/bus/input/devices into a single bitmap integer.

    The kernel prints one `unsigned long` per token, MSB-first, omitting
    leading zeros. On aarch64 / x86_64 that is 64 bits per token; on 32-bit
    platforms it would be 32 bits per token. The number of tokens depends
    on `KEY_MAX` (kernel build configuration) so we count tokens rather
    than assuming a fixed length.

    The earlier implementation assumed 32-bit tokens in LSB order; that
    matched the dump on x86 boxes but produced a wrong bitmap on aarch64
    where the kernel prints 64-bit tokens MSB-first. Concretely, on the
    Apple SMC power/lid device the buggy parser set bit 52 instead of
    bit 116 (KEY_POWER), and the classifier then mistook the power
    button for a keyboard.

    See drivers/input/input.c:input_seq_print_bitmap() for the matching
    kernel-side printer.
    """
    unsigned_long_bits = 8 * 8  # 64 bits on every platform we target.
    bits = 0
    for index, token in enumerate(tokens):
        with contextlib.suppress(ValueError):
            value = int(token, 16)
            # Token 0 is the most-significant chunk; shift it down by N
            # unsigned longs so it lands at the top of the bitmap.
            shift = (len(tokens) - 1 - index) * unsigned_long_bits
            bits |= value << shift
    return bits


def parse_input_devices(source=None) -> list[dict[str, object]]:
    """Read /proc/bus/input/devices into a structured list.

    Returns one entry per device with the values we care about: a human
    name, the eventX handler, and the populated bitset columns. Pass a
    string `source` to override the default file read; the tests use
    that to feed captured dumps without touching the live proc file.
    """
    if source is None:
        try:
            source = INPUT_DEVICES_PATH.read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return []

    entries: list[dict[str, object]] = []
    current: dict[str, object] = {}

    for line in source.splitlines():
        if line.startswith("N:"):
            # The name field is quoted: `N: Name="Apple SPI Keyboard"`. A
            # naive `.strip('"')` only strips outer quotes when the string
            # itself starts with `"`, but after `line.split(":", 1)[1]` the
            # remainder begins with ` Name=` so the leading character is
            # space. We use a regex to grab the first quoted run.
            match = re.search(r'"([^"]*)"', line)
            if match:
                current["name"] = match.group(1)
        elif line.startswith("H:"):
            # Each token after `H: Handlers=` may look like `kbd`, `event3`,
            # `mouse0`, `leds`. On multi-handler devices the line is
            # `Handlers=kbd event0 leds`; on single-handler devices it is
            # `Handlers=event3`. We accept both shapes by splitting each
            # space-separated token on `=` (so `Handlers=event3` yields
            # `event3`) and matching the `event<digit>` form with a regex.
            for handler in line.split(":", 1)[1].split():
                for token in handler.split("="):
                    if re.match(r"event\d+$", token):
                        current["event"] = token
                        break
                else:
                    continue
                break
        elif line.startswith("B: EV="):
            with contextlib.suppress(ValueError):
                current["ev"] = int(line.split("=", 1)[1].strip(), 16)
        elif line.startswith("B: KEY="):
            current["key"] = parse_keyword(line.split("=", 1)[1].split())
        elif line.strip() == "":
            if current.get("event"):
                entries.append(current)
            current = {}

    if current.get("event"):
        entries.append(current)

    return entries


def categorize(device: dict[str, object]) -> str:
    """Decide whether to grab a device as `keyboard`, `pointer`, or skip it.

    Heuristic:
    - Anything that reports relative or absolute axes is treated as a
      pointing device (mouse, trackpad, drawing tablet, touchscreen).
    - Devices with EV_KEY and many KEY bits set are real keyboards.
      Single-bit devices (power button, lid switch) and few-bit
      devices (headset volume rocker, headphone jack buttons) are
      skipped on purpose — grabbing them would silence system events
      the user still wants.
    - Anything else is skipped.

    The classifier counts set bits in the KEY bitmap rather than
    testing specific keycode positions, because keycode positions
    above 96 (KEY_KPENTER) also include power button (116), volume
    keys (113-115), and other system controls. A presence check
    against a single high position misclassifies those as keyboards.
    """
    ev = int(device.get("ev", 0))
    key = int(device.get("key", 0))
    has_rel = bool(ev & (1 << EV_REL))
    has_abs = bool(ev & (1 << EV_ABS))
    has_key_event = bool(ev & (1 << EV_KEY))

    if has_rel or has_abs:
        return "pointer"

    if has_key_event and bin(key).count("1") >= MIN_KEYBOARD_KEY_POPCOUNT:
        return "keyboard"

    return "skip"


def grab_devices(categories: set[str]) -> tuple[list[tuple[int, str, str]],
                                              list[tuple[str, str, str]],
                                              list[dict[str, object]],
                                              list[dict[str, object]]]:
    """Open every matching device and try to EVIOCGRAB it.

    Returns a 4-tuple `(grabbed, skipped, classified_keyboards,
    classified_pointers)`:

    - `grabbed` carries the live file descriptors of devices we
      successfully grabbed.
    - `skipped` records reasons for devices we wanted to grab but
      could not (open() failed, EVIOCGRAB refused).
    - `classified_keyboards` lists every device the classifier said
      was a keyboard, regardless of whether we managed to grab it.
      `main()` uses this to refuse the cleaning window when a
      classified keyboard ended up in `skipped` — a half-grabbed
      keyboard is a safety regression, not a partial success.
    - `classified_pointers` is the equivalent for pointing devices.
    """
    grabbed: list[tuple[int, str, str]] = []
    skipped: list[tuple[str, str, str]] = []
    classified_keyboards: list[dict[str, object]] = []
    classified_pointers: list[dict[str, object]] = []
    seen: set[str] = set()

    for device in parse_input_devices():
        event = device.get("event")
        name = str(device.get("name", "unknown device"))
        if not isinstance(event, str) or event in seen:
            continue
        seen.add(event)

        category = categorize(device)
        if category not in categories:
            continue

        if category == "keyboard":
            classified_keyboards.append(device)
        else:
            classified_pointers.append(device)

        path = INPUT_EVENT_ROOT / event
        try:
            fd = os.open(str(path), os.O_RDWR | os.O_NONBLOCK)
        except OSError as error:
            skipped.append((name, str(path), error.strerror or str(error)))
            continue

        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
        except OSError as error:
            os.close(fd)
            skipped.append((name, str(path), error.strerror or str(error)))
            continue

        grabbed.append((fd, str(path), name))

    return grabbed, skipped, classified_keyboards, classified_pointers


def grab_devices_for_test(devices: list[dict[str, object]],
                          categories: set[str]
                          ) -> tuple[list[tuple[int, str, str]],
                                     list[tuple[str, str, str]],
                                     list[dict[str, object]],
                                     list[dict[str, object]]]:
    """Test-only entry point: run the grab loop against a pre-parsed
    device list. Mirrors `grab_devices` exactly except for the input
    source, which lets the tests inject synthetic event paths without
    touching /proc or /dev."""
    grabbed: list[tuple[int, str, str]] = []
    skipped: list[tuple[str, str, str]] = []
    classified_keyboards: list[dict[str, object]] = []
    classified_pointers: list[dict[str, object]] = []

    for device in devices:
        event = device.get("event")
        name = str(device.get("name", "unknown device"))
        if not isinstance(event, str):
            continue
        category = categorize(device)
        if category not in categories:
            continue
        if category == "keyboard":
            classified_keyboards.append(device)
        else:
            classified_pointers.append(device)
        path = INPUT_EVENT_ROOT / event
        try:
            fd = os.open(str(path), os.O_RDWR | os.O_NONBLOCK)
        except OSError as error:
            skipped.append((name, str(path), error.strerror or str(error)))
            continue
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 1)
        except OSError as error:
            os.close(fd)
            skipped.append((name, str(path), error.strerror or str(error)))
            continue
        grabbed.append((fd, str(path), name))

    return grabbed, skipped, classified_keyboards, classified_pointers


def release_devices(grabbed: list[tuple[int, str, str]]) -> None:
    """Best-effort release of every grabbed device."""
    for fd, path, name in grabbed:
        try:
            fcntl.ioctl(fd, EVIOCGRAB, 0)
        except OSError as error:
            print(f"  ! could not release {name} ({path}): {error.strerror or error}", file=sys.stderr)
        finally:
            with contextlib.suppress(OSError):
                os.close(fd)


def has_input_group() -> bool:
    """Return True if the current user can presumably open input nodes."""
    try:
        import grp
        return grp.getgrnam("input").gr_gid in os.getgroups()
    except (KeyError, OSError):
        return False


def notify(*, replaces=None, urgency="low", headline="Keyboard Cleaner",
           body="", glyph="") -> int | None:
    """Best-effort desktop notification via Omarchy's wrapper.

    Returns the assigned D-Bus notification id when `replaces` is None and the
    wrapper is told to print it; subsequent calls pass that id back through
    `replaces=` so Quickshell refreshes the same pop-up instead of stacking new
    ones. Every failure (missing wrapper, bus down, daemon hung) is swallowed —
    a glitchy notification channel must never delay the keyboard release.
    """
    if not OMARCHY_NOTIFY_AVAILABLE:
        return None
    argv = [str(OMARCHY_NOTIFY), "-u", urgency]
    if replaces:
        argv += ["-r", str(int(replaces))]
    if glyph:
        argv += ["-g", glyph]
    argv += [headline, body]
    print_id = replaces is None
    if print_id:
        argv.append("-p")
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=0.5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    if not print_id:
        return None
    out = proc.stdout.strip()
    return int(out) if out.isdigit() else None


def render_table(rows: list[tuple[str, str]], columns: tuple[str, str, int]) -> str:
    """Build a two-column table for consistent terminal output."""
    label_width = max((len(label) for label, _ in rows), default=0)
    width = max(label_width, len(columns[0]))
    lines = []
    header = f"  {columns[0].ljust(width)}  {columns[1]}"
    lines.append(header)
    lines.append("  " + ("-" * width) + "  " + ("-" * len(columns[1])))
    for label, value in rows:
        lines.append(f"  {label.ljust(width)}  {value}")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("seconds", type=int, help="how long to block input (seconds)")
    args = parser.parse_args(argv)

    # When the launcher dispatches us directly (no terminal attached), every
    # print() would otherwise write to a broken pipe and spam the busctl log.
    # The desktop notification carries the user-visible progress; stdout is
    # debug-only, so silence it unless the host gave us a real TTY.
    if not sys.stdout.isatty():
        sys.stdout = open(os.devnull, "w", encoding="utf-8")

    if not MIN_DURATION <= args.seconds <= MAX_DURATION:
        notify(
            urgency="normal",
            body=(
                f"Duration must be between {MIN_DURATION} and {MAX_DURATION} seconds."
            ),
        )
        return 2

    duration = args.seconds
    categories = {"keyboard", "pointer"}

    print(f"Blocking keyboard and pointer devices for {duration} second(s).")

    grabbed, skipped, classified_keyboards, classified_pointers = (
        grab_devices(categories)
    )

    # Partial-failure safety: if any device we wanted to block ended up in
    # `skipped` we must NOT show the user the "wipe safely" pop-up. The
    # remaining grabbed devices are released before we surface the error,
    # so a partial grab never leaves the user with a half-blocked input
    # device (which would either silently drop keystrokes or, worse,
    # block a keyboard partially while leaving the lid-switch button
    # exposed).
    if skipped:
        release_devices(grabbed)
        if not has_input_group():
            notify(
                urgency="critical",
                body=(
                    "Could not grab any input devices: your user is not in the "
                    "'input' group. Run `sudo usermod -aG input $USER` and log out."
                ),
            )
        else:
            missing_keyboards = [
                d.get("name", "unknown") for d in classified_keyboards
                if any(d.get("name") == name for name, _, _ in skipped)
            ]
            missing_pointers = [
                d.get("name", "unknown") for d in classified_pointers
                if any(d.get("name") == name for name, _, _ in skipped)
            ]
            reasons = "; ".join(f"{name}: {reason}" for name, _, reason in skipped)
            if missing_keyboards or missing_pointers:
                missing = ", ".join(missing_keyboards + missing_pointers)
                notify(
                    urgency="critical",
                    body=(
                        f"Refusing to start: {missing} could not be grabbed "
                        f"({reasons}). Cleaning cancelled — do NOT wipe."
                    ),
                )
            else:
                notify(
                    urgency="normal",
                    body=f"Some input devices refused EVIOCGRAB ({reasons}).",
                )
        return 1

    if not grabbed:
        notify(
            urgency="normal",
            body="No input devices could be grabbed. Check /dev/input/event* access.",
        )
        return 1

    device_rows: list[tuple[str, str]] = []
    for _, path, name in grabbed:
        device_rows.append((name, path))
    print(render_table(device_rows, ("Device", "Path", 0)))
    print()

    if skipped:
        print("Skipped devices (not grabbed):")
        for name, path, reason in skipped:
            print(f"  - {name} ({path}): {reason}")
        print()

    interrupted = False

    def cleanup() -> None:
        nonlocal interrupted
        interrupted = True
        sys.stdout.write("\r\033[K")
        print("Releasing input devices...")
        release_devices(grabbed)
        print("Done. Input is restored.")
        notify(
            urgency="low",
            body="Cleaning finished. Keyboard and pointer restored.",
        )

    def handle_signal(signum: int, frame: object) -> None:
        cleanup()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGHUP, handle_signal)

    notif_id = notify(
        urgency="normal",
        glyph=KEYBOARD_GLYPH,
        body=(
            f"Blocking keyboard and pointer. Releasing in {duration}s — "
            "wipe safely."
        ),
    ) or 0

    deadline = time.monotonic() + duration
    try:
        while not interrupted:
            remaining = int(round(deadline - time.monotonic()))
            if remaining <= 0:
                break
            print(f"\r  Releasing in {remaining:3d} second(s)... ", end="", flush=True)
            if notif_id:
                notify(
                    replaces=notif_id,
                    urgency="low",
                    glyph=KEYBOARD_GLYPH,
                    body=f"Cleaning keyboard — releasing in {remaining}s.",
                )
            time.sleep(min(0.25, max(deadline - time.monotonic(), 0)))
    except KeyboardInterrupt:
        pass
    finally:
        if not interrupted:
            cleanup()

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
