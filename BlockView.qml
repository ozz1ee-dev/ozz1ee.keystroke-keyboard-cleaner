pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui as Ui
import "core/Parser.js" as Parser

// The live cleaning window: a countdown inside the palette card while
// the keyboard block is running. Keystroke loads this component over
// its results (`provider-view`), injects `host`, and calls focusInput(),
// dismiss(), beginVoice() and transcript() as documented in
// Keystroke's docs/providers.md. Colors and fonts come from the host
// and the shell's theme tokens, so every Omarchy theme styles it
// without knowing it.
//
//   Esc / Backspace  close the palette (the helper releases on its own)
Item {
  id: root
  property var host: null
  property var service: null
  property string windowLabel: ""

  readonly property color foreground: root.host ? root.host.foreground : "white"
  readonly property color muted: root.host ? root.host.muted : "#aaa"
  readonly property color accent: root.host ? root.host.accent : "#7aa2f7"
  readonly property color hairline: root.host ? root.host.hairline : "#333"
  readonly property string fontFamily: root.host && root.host.fontFamily ? root.host.fontFamily : Style.font.menuFamily
  readonly property int fontInput: root.host && root.host.fontInput ? root.host.fontInput : Style.font.heading
  readonly property int fontTitle: root.host && root.host.fontTitle ? root.host.fontTitle : Style.font.title
  readonly property int fontLabel: root.host && root.host.fontLabel ? root.host.fontLabel : Style.font.bodySmall
  readonly property int fontCaption: root.host && root.host.fontCaption ? root.host.fontCaption : Style.font.caption

  // ── local countdown ────────────────────────────────────────────
  // Snapshot the service's total seconds when the view opens and tick
  // down locally every second.  This avoids relying on QML property
  // bindings through `var service` (which never re-evaluate sub-property
  // changes) or `host.requery()` (which would rebuild the palette and
  // destroy this component mid-countdown).
  property int _total: 0
  property int _remaining: 0
  property real _startedAt: 0
  property int _tick: 0   // bumped every second → triggers binding re-eval

  readonly property int remaining: _remaining
  readonly property bool done: _remaining <= 0 && _tick > 0
  readonly property int totalSeconds: _total
  readonly property real progress: _total > 0
    ? Math.max(0, Math.min(1, 1 - _remaining / _total))
    : 0
  readonly property bool urgent: _remaining > 0 && _remaining <= 5

  function focusInput() {}
  function dismiss() {}
  function beginVoice() {}
  function transcript(text, final) {}

  // Kick off the countdown when the component is first created.  The
  // service is already active at this point (activate set active=true
  // before returning provider-view), so we can read its state directly.
  Component.onCompleted: {
    if (root.service && root.service.active) {
      root._total = root.service.activeSeconds
      root._remaining = root.service.activeSeconds
      root._startedAt = Date.now()
      root._tick = 0
    }
  }

  // Always-running 1-second tick.  With `pragma ComponentBehavior: Bound`
  // the `running` binding on `root.service.active` (a var sub-property)
  // never re-evaluates, so we check inside onTriggered instead.
  Timer {
    id: countdownTimer
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      // Sync start if the service just became active (covers the case
      // where the view was created before activate() set active=true).
      if (root._total === 0 && root.service && root.service.active) {
        root._total = root.service.activeSeconds
        root._remaining = root.service.activeSeconds
        root._startedAt = Date.now()
        root._tick = 0
      }
      if (root._remaining <= 0) return
      var elapsed = Math.floor((Date.now() - root._startedAt) / 1000)
      var left = root._total - elapsed
      root._remaining = Math.max(0, left)
      root._tick++
    }
  }

  // ── pulse animation (last 5 seconds) ──────────────────────────
  SequentialAnimation on urgentPulseOpacity {
    running: root.urgent
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.55; duration: 400; easing.type: Easing.InOutQuad }
    NumberAnimation { from: 0.55; to: 1.0; duration: 400; easing.type: Easing.InOutQuad }
  }
  property real urgentPulseOpacity: 1.0

  // A current Keystroke paints the backdrop behind this view, inside the
  // card border.  Filling the card here would cover that border, so only
  // do it for a host that does not.
  Rectangle {
    anchors.fill: parent
    visible: !(root.host && root.host.paintsViewBackdrop)
    color: root.host ? root.host.background : "#222"
  }

  component Cap: Rectangle {
    property string label: ""
    property bool bright: false
    implicitWidth: capText.implicitWidth + Style.space(12)
    implicitHeight: Style.space(22)
    radius: Math.min(Style.cornerRadius, Style.space(5))
    color: Util.alpha(root.foreground, bright ? 0.14 : 0.07)
    border.width: 1
    border.color: Util.alpha(root.foreground, bright ? 0.28 : 0.14)
    Text { id: capText; anchors.centerIn: parent; text: parent.label; textFormat: Text.PlainText; color: Util.alpha(root.foreground, parent.bright ? 0.95 : 0.6); font.family: root.fontFamily; font.pixelSize: root.fontCaption }
  }

  component ActionButton: Ui.Button {
    id: control
    property alias label: control.text
    property bool available: true
    signal triggered()
    focusable: true
    enabled: available
    opacity: enabled ? 1 : 0.4
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: root.fontLabel
    width: implicitWidth; height: implicitHeight
    onClicked: triggered()
    Keys.onReturnPressed: event => { if (!event.isAutoRepeat) triggered(); event.accepted = true }
    Keys.onEnterPressed: event => { if (!event.isAutoRepeat) triggered(); event.accepted = true }
    Keys.onSpacePressed: event => { if (!event.isAutoRepeat) triggered(); event.accepted = true }
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (enabled) triggered()
  }

  // ---------------------------------------------------------------- header
  Item {
    id: top
    x: Style.space(22); y: Style.space(12); width: parent.width - x * 2; height: Style.space(74)
    ActionButton { id: back; label: "\u2190"; tooltipText: "Back to results"; onTriggered: root.host.goBack() }
    Row {
      anchors.left: back.right; anchors.leftMargin: Style.space(10); y: Style.space(8); spacing: Style.space(10)
      Text { text: "OMARCHY"; color: root.accent; font.family: root.fontFamily; font.pixelSize: root.fontCaption; font.letterSpacing: 2; font.weight: Font.Bold }
      Text { text: "\u203a"; color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel }
      Text { text: Parser.NAME; color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel }
    }
    Cap { anchors.right: parent.right; y: Style.space(5); label: "esc" }
    Text {
      y: Style.space(43); width: parent.width
      elide: Text.ElideRight
      text: root.done
            ? "Input restored"
            : ("Releasing in " + Parser.describeDuration(root.remaining)
               + (root.windowLabel ? " \u00b7 " + root.windowLabel : ""))
      color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel
    }
  }
  Rectangle { y: top.y + top.height; width: parent.width; height: 1; color: root.hairline }

  // ---------------------------------------------------------------- main
  // Vertically centred between the header bottom and the progress bar.
  Item {
    anchors.top: parent.top
    anchors.topMargin: top.y + top.height + Style.space(14)
    anchors.bottom: barWrap.top
    anchors.left: parent.left; anchors.right: parent.right
    Column {
      anchors.centerIn: parent
      width: parent.width * 0.85
      spacing: Style.space(14)

      Text {
        opacity: root.urgent ? root.urgentPulseOpacity : 1
        Behavior on opacity { NumberAnimation { duration: 200 } }
        text: root.done ? "\u2713" : Parser.shortDuration(root.remaining)
        color: root.done
          ? root.accent
          : (root.urgent ? root.urgentPulseOpacity >= 0.75 ? root.accent : root.foreground : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: root.fontTitle * 6
        font.weight: Font.DemiBold
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        Behavior on color { ColorAnimation { duration: 200 } }
      }
      Text {
        text: root.done
              ? "Wipe finished. Keyboard and pointer restored."
              : "Wipe safely. The keyboard and pointer are blocked until the timer ends."
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: root.fontLabel
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  // ---------------------------------------------------------------- bar
  Item {
    id: barWrap
    x: Style.space(22)
    y: footerTop.y - Style.space(38)
    width: parent.width - x * 2
    height: Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.foreground, 0.08)
    }
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.progress
      radius: height / 2
      color: root.urgent
        ? (root.urgentPulseOpacity >= 0.75 ? root.accent : Util.alpha(root.accent, 0.7))
        : root.accent
      Behavior on color { ColorAnimation { duration: 200 } }
      Behavior on width { NumberAnimation { duration: 950; easing.type: Easing.Linear } }
    }
    Rectangle {
      anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
      width: Style.space(6); radius: height / 2
      color: Util.alpha(root.foreground, 0.16)
    }
  }

  // ---------------------------------------------------------------- footer
  Item {
    id: footerTop
    x: 0; y: parent.height - Style.space(44); width: parent.width; height: Style.space(44)
    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: root.hairline }
    Row {
      anchors.centerIn: parent; spacing: Style.space(16)
      ActionButton {
        id: backBtn
        label: "\u2190"
        tooltipText: "Back to results"
        onTriggered: root.host.goBack()
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Back to results"
        color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel
      }
      Rectangle { width: 1; height: Style.space(18); color: root.hairline }
      ActionButton {
        label: "Close"
        tooltipText: "Close"
        onTriggered: root.host.close()
      }
      Rectangle { width: 1; height: Style.space(18); color: root.hairline }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Total"
        color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel
      }
      Cap { label: Parser.shortDuration(root.totalSeconds) }
    }
  }
}
