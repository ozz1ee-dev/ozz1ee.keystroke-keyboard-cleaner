pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
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
// extension ships, via `Quickshell.execDetached()` so the palette closes
// immediately and the cleaning window stays on screen. A scoped view shows
// a live countdown while the block is in progress, and dismisses cleanly on
// cancel / palette close.
QtObject {
  id: root
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property string extensionDir: Quickshell.env("OMARCHY_PATH") + "/plugins/" + root.key
  property string pythonHelper: root.extensionDir + "/bin/keyboard-cleaner.py"
  property var host: null                  // the palette, captured from ctx
  property string key: manifest && manifest.id ? String(manifest.id) : Parser.DEFAULT_KEY
  // Tracks the in-flight block so the live view can render the countdown
  // and clean up on cancel. One at a time: a second `wipe` while one is
  // running refreshes the notification (matches the Omalaunch behaviour).
  property int activeSeconds: 0
  property string activeLabel: ""
  property int activeStartedAt: 0
  property bool active: false

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
    opened: function() { root.refreshView() },
    dismiss: function() { root.dismissView() }
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
      // At the palette root: show the navigation row always; if a
      // pattern matched (or the typed query parses), add the block row
      // so the user can hit Enter straight away.
      var matched = ctx.patterns && ctx.patterns.matched && ctx.patterns.matched.length > 0
      var parsed = Parser.parseQuery(q)
      var rows = [Parser.navRow(state)]
      if (matched || parsed) {
        if (!parsed) parsed = { verb: "", seconds: (ctx.settings && ctx.settings.defaultSeconds) || 30, label: "" }
        rows.push(Parser.blockRow(parsed, state))
      }
      return rows
    }
    // Inside the extension's own screen: three fixed durations.
    return Parser.screenRows(state)
  }

  function activate(row, ctx) {
    var effect = ctx.alternate && row.altAction ? row.altAction : row.action
    if (!effect) return effect
    if (effect.type === "block") {
      // Track the active block for the live view, then hand off to the
      // Python helper. The palette closes; the countdown lives inside the
      // Python helper's desktop notification now, and inside BlockView if
      // the user re-summons the palette during the window.
      root.activeSeconds = effect.seconds
      root.activeLabel = effect.label || ""
      root.activeStartedAt = Date.now()
      root.active = true
      Quickshell.execDetached(Parser.blockArgv(root.pythonHelper, effect))
      return { type: "compound", actions: [
        { type: "notify", glyph: Parser.ICON, headline: "Blocking input",
          body: "Releasing in " + Parser.describeDuration(effect.seconds)
                + (effect.label ? " · " + effect.label : "") },
        { type: "close" }
      ]}
    }
    return effect
  }

  // Called when the BlockView becomes visible (palette opens while a
  // block is running). Updates its copy of remaining seconds.
  function refreshView() {
    if (root.host && root.host.opened && root.host.scope === root.key) root.host.requery()
  }

  // Called when the palette closes while the live view is showing.
  // Nothing to flush here — the Python helper releases on its own.
  function dismissView() { /* no-op */ }

  // -------------------------------------------------------------- runtime
  // One second timer that re-evaluates the live view while a block is in
  // progress, and clears `active` when the window expires (the Python
  // helper has already released by then, but the view should stop
  // counting down).
  readonly property Timer clock: Timer {
    interval: 1000
    repeat: true
    running: root.active
    onTriggered: {
      var elapsed = Math.floor((Date.now() - root.activeStartedAt) / 1000)
      if (elapsed >= root.activeSeconds) {
        root.active = false
      } else if (root.host && root.host.opened && root.host.scope === root.key) {
        root.host.requery()
      }
    }
  }

  // Seconds left in the active block, for the view to display.
  function remainingSeconds() {
    if (!root.active) return 0
    var elapsed = Math.floor((Date.now() - root.activeStartedAt) / 1000)
    return Math.max(0, root.activeSeconds - elapsed)
  }
}
