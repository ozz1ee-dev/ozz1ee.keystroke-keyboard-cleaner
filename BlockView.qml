pragma ComponentBehavior: Bound
import QtQuick
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
//   Enter          close the palette (the helper releases on its own)
//   Esc / Backspace close the palette and return to the results
Item {
  id: root
  property var host: null
  property var service: null

  readonly property color foreground: root.host ? root.host.foreground : "white"
  readonly property color muted: root.host ? root.host.muted : "#aaa"
  readonly property color accent: root.host ? root.host.accent : "#7aa2f7"
  readonly property color hairline: root.host ? root.host.hairline : "#333"
  readonly property string fontFamily: root.host && root.host.fontFamily ? root.host.fontFamily : Style.font.menuFamily
  readonly property int fontInput: root.host && root.host.fontInput ? root.host.fontInput : Style.font.heading
  readonly property int fontTitle: root.host && root.host.fontTitle ? root.host.fontTitle : Style.font.title
  readonly property int fontLabel: root.host && root.host.fontLabel ? root.host.fontLabel : Style.font.bodySmall
  readonly property int fontCaption: root.host && root.host.fontCaption ? root.host.fontCaption : Style.font.caption

  readonly property int remaining: service ? service.remainingSeconds() : 0
  readonly property bool done: remaining <= 0

  function focusInput() {}
  function dismiss() {}
  function beginVoice() {}
  function transcript(text, final) {}

  Component.onCompleted: Qt.callLater(refresh)
  Connections {
    target: root.service
    function onActiveChanged() { root.refresh() }
  }
  Timer {
    interval: 250; repeat: true; running: root.service && root.service.active
    onTriggered: root.refresh()
  }
  function refresh() {
    if (!root.host || !root.host.opened) return
    root.host.requery()
  }

  // A current Keystroke paints the backdrop behind this view, inside the
  // card border. Filling the card here would cover that border, so only
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
               + (root.service && root.service.activeLabel ? " \u00b7 " + root.service.activeLabel : ""))
      color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel
    }
  }
  Rectangle { y: top.y + top.height; width: parent.width; height: 1; color: root.hairline }

  // ---------------------------------------------------------------- main
  Column {
    x: Style.space(22)
    y: top.y + top.height + Style.space(28)
    width: parent.width - x * 2
    spacing: Style.space(14)

    Text {
      text: root.done ? "\u2713" : Parser.shortDuration(root.remaining)
      color: root.done ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontTitle * 4
      font.weight: Font.DemiBold
    }
    Text {
      text: root.done
            ? "Wipe finished. Keyboard and pointer restored."
            : "Wipe safely. The keyboard and pointer are blocked until the timer ends."
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: root.fontLabel
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }

  // ---------------------------------------------------------------- footer
  Rectangle { y: bottom.y - Style.space(10); width: parent.width; height: 1; color: root.hairline }
  Row {
    id: bottom
    x: Style.space(18); y: parent.height - height - Style.space(16); spacing: Style.space(8); height: Style.space(30)
    ActionButton { label: "Back to results"; onTriggered: root.host.goBack() }
    Cap { anchors.verticalCenter: parent.verticalCenter; label: "\u2190"; bright: true }
    Item { width: Style.space(6); height: 1 }
    Text { anchors.verticalCenter: parent.verticalCenter; text: "Close"; color: root.muted; font.family: root.fontFamily; font.pixelSize: root.fontLabel }
    Cap { anchors.verticalCenter: parent.verticalCenter; label: "esc" }
  }
}
