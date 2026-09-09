# Changelog

All notable changes to `ozz1ee.keystroke-keyboard-cleaner` are
documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-09

### Added

- Initial release. Keystroke counterpart to the
  [`ozz1ee.keyboard-cleaner`](https://github.com/radiohost-cloud/ozz1ee.keyboard-cleaner)
  Omalaunch extension. Type `wipe 5m`, `block 30s`, `lock 1h` or `5m`
  in the palette and the cleaning window opens. A live countdown
  panel is available inside the extension's screen; the palette
  closes after Enter and the desktop notification carries the
  per-second refresh until the block expires.

  - `manifest.json` — an Omarchy `service` plugin with the
    `x-keystroke` marker Keystroke looks for; `keepLoaded: true` so
    Quickshell instantiates the QML object once at startup.
  - `Service.qml` — the provider object (`query`, `activate`,
    `opened`, `dismiss`, `settings`, `patterns`, `view`) and the
    service state. The icon is inline raw UTF-8 (Calpad/Calculator
    pattern) so it reaches Keystroke without a JS file import; the
    codepoint is Nerd Fonts `nf-md-keyboard` (U+F0313).
  - `BlockView.qml` — the live countdown that loads over the palette
    card while a block is in progress; honours the documented host
    API (`focusInput`, `dismiss`, `beginVoice`, `transcript`).
  - `core/Parser.js` — the query parser and row builders as pure
    functions, unit-tested in `tests/tst_parser.qml`. Pattern capture
    group indices are documented inline because VERB is wrapped in
    an outer `(...)` capture group plus an inner alternation, which
    silently shifts digit capture from `m[2]` to `m[3]`.
  - `bin/keyboard-cleaner.py` — the helper shared with the Omalaunch
    extension, unchanged from `ozz1ee.keyboard-cleaner` v0.3.0.
  - `tests/tst_parser.qml` — 20 unit tests (`qmltestrunner`) for the
    parser: pattern compilation, recognition of every supported
    shape (verb+duration with spelled-out units, bare duration, verb
    only), clamping to `MIN_SECONDS..MAX_SECONDS`, duration formatting,
    and a regression test that locks the icon codepoint in place
    (an earlier draft encoded the PUA as `\U000F0313`, an
    8-digit uppercase-U JavaScript escape that most engines do not
    implement and silently read as literal characters).
  - `tests/test_devices.py` — 16 Python unit tests for the shared
    helper, covering the `/proc/bus/input/devices` parser, the
    keyboard/trackpad/power-button/headphone-jack classifier, and the
    partial-failure contract.
