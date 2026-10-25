import QtQuick

// A search filter: its name when unset; its value and a way to clear it
// when set. Both states say what they are in words, not just colour.
Rectangle {
  id: root

  required property var theme
  property string icon: ""
  property string label: ""
  property string value: ""
  readonly property bool active: value !== ""

  signal choose()
  signal clear()

  implicitWidth: row.implicitWidth + theme.space(active ? 8 : 20)
  implicitHeight: theme.space(28)
  radius: theme.radius
  color: active ? theme.selectedFill : (mouse.containsMouse ? theme.hoverFill : "transparent")
  border.width: theme.borderWidth
  border.color: active ? theme.accent : theme.border

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.choose()
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    x: root.theme.space(10)
    spacing: root.theme.space(6)
    Glyph {
      name: root.icon
      size: root.theme.small + 1
      color: root.active ? root.theme.accent : root.theme.foreground
      font.family: root.theme.font
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: root.active ? root.label + ": " + root.value : root.label + "..."
      textFormat: Text.PlainText
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      anchors.verticalCenter: parent.verticalCenter
    }
    IconButton {
      visible: root.active
      theme: root.theme
      icon: "close"
      size: root.theme.space(22)
      iconSize: root.theme.small
      tooltip: "Remove this filter"
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.clear()
    }
  }
}
