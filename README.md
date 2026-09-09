# Keyboard Cleaner for Keystroke

A [Keystroke](https://github.com/evindor/keystroke) community extension
that blocks the keyboard and pointer for a chosen duration so they can
be wiped down without triggering anything. Type `wipe 5m`, `block 30s`,
`lock 1h` or `5m` in the palette and the cleaning window opens.

This is the Keystroke counterpart to the
[`ozz1ee.keyboard-cleaner`](https://github.com/radiohost-cloud/ozz1ee.keyboard-cleaner)
Omalaunch extension. The Python helper is shared between them, so a
half-grabbed input device behaves the same way whichever launcher the
user came from.

## Install

Requires Omarchy 4.0.2 or newer with Keystroke enabled as the menu.

From the palette: open **Extensions** (type `ext`), pick **Keyboard
Cleaner**, confirm. Or from a terminal:

```sh
omarchy plugin add https://github.com/radiohost-cloud/ozz1ee.keystroke-keyboard-cleaner.git --enable
```

Extensions installed from the terminal start switched off inside
Keystroke; turn this one on under **Extensions → Keyboard Cleaner →
Enabled** (or **Keystroke Settings → Keyboard Cleaner**). Extensions
installed from the palette are enabled straight away.

### After installing

Restart the shell so the new `Service.qml` and `core/Parser.js` are
picked up — `omarchy plugin enable` only adds the plugin to the
registry, it does not hot-reload an already-running shell:

```sh
omarchy restart shell
```

## Use

| Query | Result |
| --- | --- |
| `wipe 5m` | Block for 5 minutes |
| `block 30s` | Block for 30 seconds |
| `lock 1h` | Block for 1 hour |
| `clean 2 minutes` | Block for 2 minutes (spelled-out unit) |
| `5m` · `30s` · `1h` | Bare duration, no verb |
| `wipe` · `block` | A verb with no duration uses Settings → Default duration |
| `block 30s keyboard` | A trailing word becomes a label that ends up in the notification body |

Enter starts the block and closes the palette. A desktop notification
("Blocking keyboard and pointer. Releasing in 30s — wipe safely.")
appears at the top-right and refreshes in place every second. When the
timer ends the pop-up turns into a "Cleaning finished" toast.

A live countdown panel is also available: enter the extension's screen
(type `keyboard-cleaner` and pick the navigation row, then Enter), and
the **Block for 30 seconds** row opens the same countdown inside the
palette. Press Esc or `←` to close it without stopping the block.

Settings → Keyboard Cleaner:

- **Default duration (seconds)** — used by `wipe` and similar verbs
  with no duration typed. Default 30, range 1..3600.

## Settings

Values live under `providers.ozz1ee.keystroke-keyboard-cleaner` in
`~/.config/omarchy/keystroke.json`.

## Remove

From the palette: **Extensions → Keyboard Cleaner → Remove**. Or:

```sh
omarchy plugin remove ozz1ee.keystroke-keyboard-cleaner
```

Removal unloads the service and deletes the folder under
`~/.config/omarchy/plugins/`. Your settings in `keystroke.json` are
left alone; delete the `providers.ozz1ee.keystroke-keyboard-cleaner`
block by hand if you want them gone.

## Limits and dependencies

- The helper blocks every keyboard and pointing device via
  `EVIOCGRAB`, so the kernel stops delivering events from every
  grabbed node until the timer expires. Power buttons, lid switches
  and headphone jack buttons are intentionally left alone.
- One block at a time. A second `wipe` while one is running replaces
  the notification and the live countdown without spawning a second
  helper. The earlier helper's timer still expires on its own; the
  keyboard releases when the latest timer ends.
- `input` group membership is required. `omarchy plugin remove` does
  not drop the user from the group — that is broader than this
  extension and any Wayland input handling breaks without it.
- Notifications go through Omarchy's own `omarchy-notification-send`;
  no sudo, no network, no daemons.
- Like every Omarchy plugin, this one runs unsandboxed inside your
  shell with your permissions. Read `Service.qml` before you enable
  it; it is short.

## Verify

```sh
cd ozz1ee.keystroke-keyboard-cleaner
omarchy plugin validate .          # manifest + entry-point existence
/usr/lib/qt6/bin/qmltestrunner -input tests/tst_parser.qml
python3 tests/test_devices.py
```

Two test layers, both stdlib / Qt-only:

- `tests/tst_parser.qml` — `qmltestrunner` unit tests for the pure JS
  parser in `core/Parser.js`: pattern compilation, pattern
  recognition of every supported shape, parsing of verb+durations
  with labels and spelled-out units, clamping to `MIN_SECONDS..MAX_SECONDS`,
  duration formatting.
- `tests/test_devices.py` — Python `unittest` for the same helper the
  Omalaunch extension ships, covering the `/proc/bus/input/devices`
  parser, the keyboard/trackpad/power-button/headphone-jack
  classifier, and the partial-failure contract.

The live `qmllint` output reports a long list of "unqualified access"
warnings for `Style.*` and `Util.*` tokens from `qs.Commons` and
`qs.Ui`. These are the same warnings the published Calpad
`SessionView.qml` produces against a standalone `qmllint`; the host
ships the type info at runtime.

## Develop

Layout:

- `manifest.json` — an Omarchy `service` plugin with the
  `x-keystroke` marker Keystroke looks for.
- `Service.qml` — the provider object (`query`, `activate`, `opened`,
  `dismiss`, `settings`, `patterns`, `view`) and the service state.
- `BlockView.qml` — the live countdown that loads over the palette
  card while a block is in progress.
- `core/Parser.js` — the query parser and row builders as pure
  functions, unit-tested in `tests/tst_parser.qml`.
- `bin/keyboard-cleaner.py` — the helper shared with the Omalaunch
  extension, unchanged from `ozz1ee.keyboard-cleaner` v0.3.0.

To iterate on a local checkout, copy it into place (Omarchy refuses
symlinks inside plugin folders):

```sh
rsync -a --delete --exclude .git --exclude __pycache__ ./ ~/.config/omarchy/plugins/ozz1ee.keystroke-keyboard-cleaner/
omarchy restart shell
```

**Important**: `omarchy plugin enable` and `rescanPlugins` only
update the registry. The running `omarchy-shell` process keeps the
old `Service.qml` cached until you `omarchy restart shell`.

## License

[MIT](LICENSE).
