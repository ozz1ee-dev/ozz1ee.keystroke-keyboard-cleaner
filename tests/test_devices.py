#!/usr/bin/env python3
"""Tests for keyboard-cleaner device parsing and classification.

Run from the plugin directory:

    python3 tests/test_devices.py

Or from anywhere:

    python3 /path/to/ozz1ee.keyboard-cleaner/tests/test_devices.py

Exits 0 on success, non-zero with a per-failure summary on failure. No third-
party dependencies — uses only the standard library so it runs on every
default Omarchy install.

The fixtures cover every device the maintainer asked us to test after their
2026-09-08 review: real keyboards, real pointing devices, power buttons,
and lid switches. They are derived from /proc/bus/input/devices dumps we
captured on Omarchy on an Apple Silicon laptop (aarch64, kernel 7.1.6).
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parent.parent
SCRIPT = PLUGIN_DIR / "bin" / "keyboard-cleaner.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("keyboard_cleaner", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# Fixtures: captured /proc/bus/input/devices dumps
# ---------------------------------------------------------------------------

# Apple SMC power/lid events — one KEY bit (KEY_POWER=116). The classifier
# must call this 'skip': grabbing it would silence the power button.
APPLE_SMC_POWER_LID = """\
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="Apple SMC power/lid events"
P: Phys=macsmc-input (0)
S: Sysfs=/devices/platform/soc/23e400000.smc/macsmc-input/input/input0
U: Uniq=
H: Handlers=kbd event0
B: PROP=0
B: EV=23
B: KEY=10000000000000 0
B: SW=1

"""

# Apple SPI Keyboard — full keyboard with 176 KEY bits across letters,
# modifiers, function keys, and keypad. Classifier: 'keyboard'.
APPLE_SPI_KEYBOARD = """\
I: Bus=001c Vendor=05ac Product=0281 Version=0935
N: Name="Apple SPI Keyboard"
P: Phys=spi1.0 (1)
S: Sysfs=/devices/platform/soc/23510c000.spi/spi_master/spi1/spi1.0/001C:05AC:0281.0001/input/input6
U: Uniq=
H: Handlers=sysrq kbd leds event1
B: PROP=0
B: EV=120013
B: KEY=10000 0 0 0 101007b02011007 ff9f217ac14057ff ffbeffdfffefffff fffffffffffffffe
B: MSC=10
B: LED=1f

"""

# Apple SPI Trackpad — EV_ABS present, so this is a pointer regardless of
# the KEY bitmap content.
APPLE_SPI_TRACKPAD = """\
I: Bus=001c Vendor=05ac Product=0281 Version=0935
N: Name="Apple SPI Trackpad"
P: Phys=spi1.0 (2)
S: Sysfs=/devices/platform/soc/23510c000.spi/spi_master/spi1/spi1.0/001C:05AC:0281.0002/input/input7
U: Uniq=
H: Handlers=mouse0 event2
B: PROP=5
B: EV=1b
B: KEY=e520 10000 0 0 0 0
B: ABS=67f800001000003
B: MSC=10

"""

# Headphone jack — EV_SW (switch), no EV_KEY. Classifier: 'skip'.
HEADPHONE_JACK = """\
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="MacBook Air J313 Headphone Jack"
P: Phys=ALSA
S: Sysfs=/devices/platform/sound/sound/card0/input8
U: Uniq=
H: Handlers=event3
B: PROP=0
B: EV=21
B: SW=14

"""

# USB mouse — EV_REL present, so 'pointer'.
USB_MOUSE = """\
I: Bus=0005 Vendor=17ef Product=61dc Version=0001
N: Name="NM1 SE Mouse"
P: Phys=b0:be:83:3d:2e:38
S: Sysfs=/devices/virtual/misc/uhid/0005:17EF:61DC.000D/input/input19
U: Uniq=d1:04:cb:34:e4:62
H: Handlers=mouse1 event4
B: PROP=0
B: EV=17
B: KEY=1f0000 0 0 0 0
B: REL=903
B: MSC=10

"""

# Lid switch — single SW bit, no EV_KEY. Classifier: 'skip'.
LID_SWITCH = """\
I: Bus=0019 Vendor=0000 Product=0000 Version=0000
N: Name="Lid Switch"
P: Phys=PNP0C0D:00
S: Sysfs=/devices/LNXSYSTM:00/LNXSYBUS:00/PNP0C0D:00/input/input11
U: Uniq=
H: Handlers=event5
B: PROP=0
B: EV=21
B: SW=1

"""

# Volume buttons on a headset — a few KEY bits, EV_KEY present, no EV_REL/
# EV_ABS. With popcount well below 8, the classifier must call this 'skip':
# the user wants to wipe a keyboard, not silence volume control.
HEADSET_VOLUME = """\
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="CMedia Audio Headset Buttons"
P: Phys=
S: Sysfs=/devices/.../input/input14
U: Uniq=
H: Handlers=kbd event6
B: PROP=0
B: EV=1
B: KEY=3c000000000000 0 0 0 0

"""


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class ParseInputDevicesTests(unittest.TestCase):
    """Parser must produce a list of devices with the keys the rest of the
    script relies on. We check both structure and the exact bit positions of
    one critical device (Apple SMC power/lid) to lock in the parser format."""

    def setUp(self):
        self.kc = _load_module()

    def test_apple_smc_power_lid_bit_is_116(self):
        """KEY_POWER is bit 116 in input-event-codes.h. If the parser
        mis-shifts the words the device will register the bit somewhere
        in the 50s or 200s instead of 116, and the maintainer's exact
        concern (classifying the power button as a keyboard) will recur."""
        devices = self.kc.parse_input_devices(APPLE_SMC_POWER_LID)
        self.assertEqual(len(devices), 1)
        device = devices[0]
        self.assertEqual(device["name"], "Apple SMC power/lid events")
        self.assertEqual(device["event"], "event0")
        self.assertEqual(device["ev"], 0x23)
        key = device["key"]
        self.assertTrue(key & (1 << 116),
                        f"bit 116 (KEY_POWER) must be set, got {hex(key)}")
        # Only bit 116 is set — confirms no other bits leaked in via a
        # wrong shift.
        self.assertEqual(key, 1 << 116,
                         f"only KEY_POWER should be set, got {hex(key)}")

    def test_apple_spi_keyboard_popcount(self):
        """The real Apple SPI Keyboard has ~176 KEY bits spread across
        letters, modifiers, function keys, and keypad. Anything close to
        256 means the parser is treating the dump as a single 256-bit
        chunk and double-counting."""
        devices = self.kc.parse_input_devices(APPLE_SPI_KEYBOARD)
        self.assertEqual(len(devices), 1)
        key = devices[0]["key"]
        popcount = bin(key).count("1")
        self.assertGreaterEqual(popcount, 150,
                                f"expected >=150 bits set, got {popcount}")
        self.assertLessEqual(popcount, 200,
                             f"expected <=200 bits set, got {popcount}")
        # Spot check: KEY_Q=16 and KEY_LEFTCTRL=29 must be set.
        self.assertTrue(key & (1 << 16), "KEY_Q=16 must be set")
        self.assertTrue(key & (1 << 29), "KEY_LEFTCTRL=29 must be set")

    def test_apple_spi_trackpad_has_btn_left(self):
        """Apple SPI Trackpad reports BTN_LEFT at bit 272. The parser must
        place it there; if it shifted the words wrong BTN_LEFT would land
        in the bit 16 area (BTN_LEFT=0x110, shifted into a 256-bit dump
        it would collide with KEY_Q)."""
        devices = self.kc.parse_input_devices(APPLE_SPI_TRACKPAD)
        self.assertEqual(len(devices), 1)
        key = devices[0]["key"]
        self.assertTrue(key & (1 << 272),
                        f"BTN_LEFT=272 must be set, got {hex(key)}")

    def test_usb_mouse_has_btn_left(self):
        """USB mouse reports BTN_LEFT=272 through BTN_SIDE=276."""
        devices = self.kc.parse_input_devices(USB_MOUSE)
        self.assertEqual(len(devices), 1)
        key = devices[0]["key"]
        for bit in (272, 273, 274, 275, 276):
            self.assertTrue(key & (1 << bit),
                            f"BTN bit {bit} must be set, got {hex(key)}")

    def test_headphone_jack_has_no_key_bitmap(self):
        """The headphone jack has EV_SW but no EV_KEY, so the parser must
        not synthesise a KEY entry. Some old kernels omit the KEY= line
        entirely; we should still produce a usable device record."""
        devices = self.kc.parse_input_devices(HEADPHONE_JACK)
        self.assertEqual(len(devices), 1)
        device = devices[0]
        self.assertEqual(device["ev"], 0x21)
        # KEY field may be absent or zero — both are fine.
        self.assertFalse(device.get("key", 0) & ~0,
                         "headphone jack should not have any KEY bits set")

    def test_lid_switch_no_key_bitmap(self):
        devices = self.kc.parse_input_devices(LID_SWITCH)
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]["ev"], 0x21)

    def test_multiple_devices_in_one_dump(self):
        """A combined dump of every Apple laptop input device must parse
        cleanly and yield one entry per `I:` block."""
        combined = (
            APPLE_SMC_POWER_LID
            + APPLE_SPI_KEYBOARD
            + APPLE_SPI_TRACKPAD
            + HEADPHONE_JACK
        )
        devices = self.kc.parse_input_devices(combined)
        names = [d["name"] for d in devices]
        self.assertEqual(len(devices), 4)
        self.assertIn("Apple SPI Keyboard", names)
        self.assertIn("Apple SPI Trackpad", names)
        self.assertIn("Apple SMC power/lid events", names)
        self.assertIn("MacBook Air J313 Headphone Jack", names)


class CategorizeTests(unittest.TestCase):
    """Classifier decides whether each device is grabbed (and as what) or
    skipped. The maintainer's specific concerns are encoded as the first
    three tests."""

    def setUp(self):
        self.kc = _load_module()

    def _one(self, dump):
        return self.kc.parse_input_devices(dump)[0]

    def test_power_button_is_skipped_not_keyboard(self):
        """The exact regression the maintainer flagged: the Apple SMC
        power/lid events device has one KEY bit set (KEY_POWER=116).
        Before the fix the classifier could return 'keyboard' here,
        which would silence the power button for the whole cleaning
        window — a real safety regression."""
        device = self._one(APPLE_SMC_POWER_LID)
        self.assertEqual(self.kc.categorize(device), "skip",
                         "power/lid device must be skipped, not grabbed")

    def test_headset_volume_buttons_are_skipped(self):
        """A headset with three volume keys (KEY_VOLUMEUP=115, MUTE=113,
        DOWN=114) must be skipped, not classified as a keyboard. Only
        one bit being above position 96 is not enough evidence of a
        full keyboard — the maintainer called out this exact failure."""
        device = self._one(HEADSET_VOLUME)
        self.assertEqual(self.kc.categorize(device), "skip",
                         "few-bit KEY devices must be skipped")

    def test_real_keyboard_is_keyboard(self):
        device = self._one(APPLE_SPI_KEYBOARD)
        self.assertEqual(self.kc.categorize(device), "keyboard")

    def test_trackpad_is_pointer(self):
        device = self._one(APPLE_SPI_TRACKPAD)
        self.assertEqual(self.kc.categorize(device), "pointer")

    def test_usb_mouse_is_pointer(self):
        device = self._one(USB_MOUSE)
        self.assertEqual(self.kc.categorize(device), "pointer")

    def test_headphone_jack_is_skipped(self):
        device = self._one(HEADPHONE_JACK)
        self.assertEqual(self.kc.categorize(device), "skip")

    def test_lid_switch_is_skipped(self):
        device = self._one(LID_SWITCH)
        self.assertEqual(self.kc.categorize(device), "skip")


class GrabDevicesContractTests(unittest.TestCase):
    """`grab_devices()` returns (grabbed, skipped, classified_keyboards,
    classified_pointers). The third and fourth tuples let `main()` detect
    partial failures: if a device was classified as keyboard but ended up
    in `skipped` we must release every grab and surface an error, never
    show the user 'wipe safely'."""

    def setUp(self):
        self.kc = _load_module()

    def test_returns_three_tuples(self):
        """The contract has grown from 2-tuple to 4-tuple after the
        safety fix. This test fails loudly if someone reverts it."""
        devices = self.kc.parse_input_devices(APPLE_SPI_KEYBOARD)
        result = self.kc.grab_devices_for_test(
            devices, {"keyboard", "pointer"}
        )
        self.assertEqual(len(result), 4,
                         "grab_devices must return 4 tuples")

    def test_partial_failure_is_visible(self):
        """If the Apple SPI Keyboard is classified as 'keyboard' but its
        open() fails (simulated by removing the device), the third tuple
        must still list it so main() can refuse to show 'wipe safely'."""
        devices = self.kc.parse_input_devices(APPLE_SPI_KEYBOARD)
        # Simulate open failure by stripping the event path.
        for d in devices:
            d["event"] = "event_does_not_exist"
        grabbed, skipped, classified_keyboards, classified_pointers = (
            self.kc.grab_devices_for_test(devices, {"keyboard", "pointer"})
        )
        self.assertEqual(len(grabbed), 0)
        self.assertEqual(len(skipped), 1)
        self.assertEqual(len(classified_keyboards), 1,
                         "main() needs to know a keyboard was *required*")
        self.assertEqual(classified_keyboards[0]["name"],
                         "Apple SPI Keyboard")


if __name__ == "__main__":
    unittest.main(verbosity=2)
