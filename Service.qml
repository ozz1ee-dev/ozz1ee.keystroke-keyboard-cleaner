pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "core/Parser.js" as Parser

// Keyboard Cleaner for Keystroke: a community provider for the Keystroke
// command palette.
//
// Omarchy loads this object into omarchy-shell as a headless service (kind
// "service", keepLoaded), injects `shell`, `manifest` and `omarchyPath`, and
// destroys it when the plugin is disabled or removed. Keystroke finds it
// through the `x-keystroke` marker in the manifest and reads `provider`.
//
// The provider declares the query shapes it understands as `patterns`; when
// one matches, Keystroke lifts the row and tells us which shapes matched
// (ctx.patterns). Activation runs the same Python helper the Omalaunch
// extension ships, via `bash -lc` (with an existence guard) so the
// palette closes immediately and the cleaning window stays on screen. A
// scoped view shows a live countdown while the block is in progress, and
// dismisses cleanly on cancel / palette close.
//
// The root is Item rather than QtObject: every first-party service in
// Omarchy (idle, media, notifications) uses Item because Item carries the
// default `data` property that lets plain children like FileView and
// Timer attach without an explicit `parent:` / `data: [ … ]` wrapper.
// QtObject would warn "Cannot assign to non-existent default property"
// at qmllint time and load unreliably at runtime.
Item {
  id: root
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  // Resolve the helper next to the QML file so it lives wherever `omarchy
  // plugin add` installed the bundle (typically
  // `~/.config/omarchy/plugins/<id>/bin/keyboard-cleaner.py`). Building a path
  // from $OMARCHY_PATH broke stock Omarchy installs: OMARCHY_PATH points to
  // `/usr/share/omarchy`, but the plugin is installed into the user config
  // directory, so `execDetached` failed silently while the notification
  // still claimed input was blocked — exactly the failure mode the plugin is
  // meant to prevent.
  property string pythonHelper: String(Qt.resolvedUrl("bin/keyboard-cleaner.py")).replace(/^file:\/\//, "")
  // Cached existence check on the helper. Keystroke's `activate` returns
  // synchronously and `Quickshell.execDetached` is fire-and-forget, so the
  // only safe place to verify the helper is at load time. `present` flips to
  // true once FileView has finished and the file is there; `unknown` covers
  // the race window between `Component.onCompleted` and the first activate.
  property int helperStatus: 0  // -1 missing, 0 unknown, 1 present
  // Cached existence check on the helper. Keystroke's `activate` returns
  // synchronously and `Quickshell.execDetached` is fire-and-forget, so
  // the only safe place to verify the helper is at load time. The shape
  // is `property FileView` (not `readonly property FileView`, and not a
  // child FileView under a QtObject) — every other service plugin in
  // Omarchy does it this way because QtObject has no default property
  // and `readonly property FileView` is rejected by qmllint as
  // "Cannot assign to non-existent default property".
  property FileView helperProbe: FileView {
    path: root.pythonHelper
    printErrors: false
    onLoaded: { root.helperStatus = 1 }
    onLoadFailed: { root.helperStatus = -1 }
  }
  Component.onCompleted: { helperProbe.reload() }
  property var host: null                  // the palette, captured from ctx
  property string key: manifest && manifest.id ? String(manifest.id) : Parser.DEFAULT_KEY
  // Tracks the in-flight block so the live view can render the countdown
  // and clean up on cancel. One at a time: a second `wipe` while one is
  // running refreshes the notification (matches the Omalaunch behaviour).
  property int activeSeconds: 0
  property string activeLabel: ""
  property int activeStartedAt: 0
  property bool active: false
  property int remaining: 0

  // -------------------------------------------------------------- provider

  // Inline raw UTF-8 glyph (Calpad/Calculator pattern) so the icon reaches
  // Keystroke without going through a JS file import. The codepoint is
  // Nerd Fonts nf-md-keyboard (U+F0313). Resolved `iconSource` ships the same
  // shape as a SVG so a host whose palette font does not resolve the PUA
  // codepoint at runtime falls back to the image.
  readonly property string providerIcon: "󰌓"
  readonly property var provider: ({
    apiVersion: 1,
    name: Parser.NAME,
    icon: providerIcon,
    color: Parser.COLOR,
    description: "Block the keyboard and pointer for a chosen duration so the keyboard can be wiped without triggering keys",
    prefix: "wipe",
    patterns: Parser.PATTERNS,
    settings: [
      { key: "defaultSeconds", type: "number", label: "Default duration (seconds)",
        "default": 30, min: 1, max: 3600, integer: true,
        description: "Used by `wipe` and similar verbs with no duration typed" }
    ],
    view: root.view,
    query: function(ctx) { return root.query(ctx) },
    activate: function(row, ctx) { return root.activate(row, ctx) },
    opened: function() {},
    dismiss: function() {}
  })

  // The live view: a small panel inside the palette card showing the
  // remaining seconds. Loaded by Keystroke when the provider returns
  // `{type: "provider-view", provider: key}` from activate(); the host
  // calls `focusInput()`, `dismiss()`, `beginVoice()` and `transcript()`
  // as documented in docs/providers.md.
  readonly property Component view: Component { BlockView { service: root } }

  // ------------------------------------------------------------------ query
  function query(ctx) {
    root.host = ctx.host
    if (ctx.scope && ctx.scope !== key) return []
    var q = String(ctx.query || "").trim()
    var state = { key: key, iconSource: "" }
    if (!ctx.scope) {
      // At the palette root, only show the navigation row for an empty
      // query — otherwise it would surface for every typed token (the
      // host skips its own matcher when a row carries an explicit score,
      // which made "Keyboard Cleaner" follow `firefox` and friends). The
      // block row alone is enough once the user has typed something.
      if (!q) return [Parser.navRow(state)]
      // Inside the extension's own screen: three fixed durations.
      var matched = ctx.patterns && ctx.patterns.matched && ctx.patterns.matched.length > 0
      var parsed = Parser.parseQuery(q)
      if (matched || parsed) {
        if (!parsed) parsed = { verb: "", seconds: (ctx.settings && ctx.settings.defaultSeconds) || 30, label: "" }
        return [Parser.blockRow(parsed, state)]
      }
      return []
    }
    return Parser.screenRows(state)
  }

  function activate(row, ctx) {
    var effect = ctx.alternate && row.altAction ? row.altAction : row.action
    if (!effect) return effect
    if (effect.type === "block") {
      // If the helper probe finished and the file is missing, refuse to
      // launch. Showing "Blocking input" while nothing is grabbed is the
      // exact failure mode this plugin exists to prevent. The probe runs
      // once at load time, so by the time the user activates the helper
      // status is known — except during the brief window before
      // `Component.onCompleted` fires, where we let the call through and
      // trust bash's `[ -x ]` to surface the error.
      if (root.helperStatus === -1) {
        return { type: "compound", actions: [
          { type: "notify", glyph: Parser.ICON, headline: "Keyboard Cleaner not installed",
            body: "The helper script is missing from this plugin bundle. Reinstall with `omarchy plugin remove ozz1ee.keystroke-keyboard-cleaner && omarchy plugin add https://github.com/radiohost-cloud/ozz1ee.keystroke-keyboard-cleaner.git --enable`." },
          { type: "close" }
        ]}
      }
      // Track the active block for the live view, then hand off to the
      // Python helper. Every block opens the live countdown view in the
      // palette so the user can see how much time is left and dismiss
      // it cleanly; the helper drives the desktop notification too,
      // but the palette countdown is what gives the user a place to
      // return to if they want to watch the timer run down.
      root.activeSeconds = effect.seconds
      root.activeLabel = effect.label || ""
      root.activeStartedAt = Date.now()
      root.remaining = effect.seconds
      root.active = true
      var argv = Parser.blockArgv(root.pythonHelper, effect)
      Quickshell.execDetached(["bash", "-lc",
        "export KEYBOARD_CLEANER_NO_NOTIFY=1; [ -x \"" + root.pythonHelper + "\" ] || { echo 'ozz1ee.keystroke-keyboard-cleaner: helper not executable at " + root.pythonHelper + "' >&2; exit 127; }; exec " +
        argv.map(function(a) { return "\"" + a.replace(/"/g, "\\\\\"") + "\""; }).join(" ")
      ])
      return { type: "provider-view", provider: key, seconds: effect.seconds, label: effect.label }
    }
    return effect
  }

  // -------------------------------------------------------------- runtime
  // Single-purpose timer: clears `active` when the block window expires.
  // BlockView manages its own local countdown for the live view.
  Timer {
    id: clock
    interval: 1000
    repeat: true
    running: root.active
    onTriggered: {
      var elapsed = Math.floor((Date.now() - root.activeStartedAt) / 1000)
      if (elapsed >= root.activeSeconds) {
        root.active = false
      }
    }
  }
}
