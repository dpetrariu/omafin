import QtQuick

// A short message at the bottom of the window that goes away by itself. An
// optional action (Undo, Show) sits beside it.
Rectangle {
  id: root

  required property var theme
  property string message: ""
  property string tone: "info"   // info | error
  property string actionText: ""
  property var action: null

  function show(text, options) {
    options = options || {}
    message = text
    tone = options.tone || "info"
    actionText = options.actionText || ""
    action = options.action || null
    hideTimer.interval = options.duration || (tone === "error" ? 7000 : 3500)
    hideTimer.restart()
    visible = true
  }

  visible: false
  z: 400
  width: Math.min(parent.width - theme.space(48), row.implicitWidth + theme.space(28))
  height: row.implicitHeight + theme.space(18)
  radius: theme.radius
  color: theme.popupBackground
  border.width: theme.borderWidth
  border.color: tone === "error" ? theme.urgent : theme.popupBorder

  Timer {
    id: hideTimer
    onTriggered: root.visible = false
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onEntered: hideTimer.stop()
    onExited: hideTimer.restart()
    onClicked: root.visible = false
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(14)
    Glyph {
      name: root.tone === "error" ? "error" : "info"
      size: root.theme.icon
      color: root.tone === "error" ? root.theme.urgent : root.theme.accent
      font.family: root.theme.font
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: root.message
      textFormat: Text.PlainText
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, root.parent ? root.parent.width * 0.6 : 600)
      wrapMode: Text.Wrap
    }
    TextButton {
      visible: root.actionText !== ""
      theme: root.theme
      text: root.actionText
      primary: true
      anchors.verticalCenter: parent.verticalCenter
      onClicked: {
        root.visible = false
        if (typeof root.action === "function") root.action()
      }
    }
  }
}
