import QtQuick
import "../keys/Keymap.js" as Keymap

// The bottom edge: where sync stands, what the window is showing, and the
// keys that work right here.
Item {
  id: root

  required property var theme
  property string context: "grid"
  property string leftText: ""
  property string leftIcon: ""
  property bool leftAttention: false
  property bool leftBusy: false
  property string middleText: ""
  property bool sidebarCollapsed: false

  signal sidebarToggled()
  signal leftClicked()

  implicitHeight: theme.space(30)

  Rectangle {
    width: parent.width
    height: root.theme.borderWidth
    color: root.theme.border
  }

  IconButton {
    id: sidebarButton
    theme: root.theme
    anchors.left: parent.left
    anchors.leftMargin: root.theme.space(6)
    anchors.verticalCenter: parent.verticalCenter
    icon: "sidebar"
    size: root.theme.space(24)
    iconSize: root.theme.small + 2
    color: root.theme.dim
    tooltip: root.sidebarCollapsed ? "Expand the sidebar (Ctrl+B)" : "Collapse the sidebar (Ctrl+B)"
    onClicked: root.sidebarToggled()
  }

  Row {
    anchors.left: sidebarButton.right
    anchors.leftMargin: root.theme.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.theme.space(6)
    Glyph {
      visible: root.leftIcon !== ""
      name: root.leftIcon
      size: root.theme.small + 1
      color: root.leftAttention ? root.theme.urgent : root.theme.dim
      font.family: root.theme.font
      anchors.verticalCenter: parent.verticalCenter
      RotationAnimation on rotation {
        running: root.leftBusy
        from: 0; to: 360; duration: 1400; loops: Animation.Infinite
      }
    }
    Text {
      text: root.leftText
      textFormat: Text.PlainText
      color: root.leftAttention ? root.theme.urgent : root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      anchors.verticalCenter: parent.verticalCenter
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.leftClicked()
      }
    }
    Text {
      visible: root.middleText !== ""
      text: "·  " + root.middleText
      textFormat: Text.PlainText
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  Row {
    anchors.right: parent.right
    anchors.rightMargin: root.theme.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.theme.space(12)
    Repeater {
      model: Keymap.hintsFor(root.context)
      delegate: Row {
        required property var modelData
        spacing: root.theme.space(5)
        Rectangle {
          width: keyText.implicitWidth + root.theme.space(8)
          height: keyText.implicitHeight + root.theme.space(2)
          radius: root.theme.radius
          color: root.theme.raised
          anchors.verticalCenter: parent.verticalCenter
          Text {
            id: keyText
            anchors.centerIn: parent
            text: modelData.key
            textFormat: Text.PlainText
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        Text {
          text: modelData.label
          textFormat: Text.PlainText
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
