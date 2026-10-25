import QtQuick
import "../components"

// A heading inside a page, with an optional link to see everything.
Item {
  id: root
  required property var theme
  property string text: ""
  property string action: ""
  signal actionClicked()
  width: parent ? parent.width : 0
  implicitHeight: theme.space(26)

  Text {
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    text: root.text
    textFormat: Text.PlainText
    color: root.theme.foreground
    font.family: root.theme.font
    font.pixelSize: root.theme.title
    font.bold: true
  }
  Text {
    visible: root.action !== ""
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.action + "  ›"
    textFormat: Text.PlainText
    color: mouse.containsMouse ? root.theme.accent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.actionClicked() }
  }
}
