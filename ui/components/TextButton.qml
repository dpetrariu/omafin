import QtQuick

// A labelled action. `primary` draws the bordered form used for the one
// action a surface is for; `danger` uses the theme's urgent colour.
Item {
  id: root

  required property var theme
  property string text: ""
  property string icon: ""
  property bool primary: false
  property bool danger: false
  property bool selected: false
  property bool busy: false
  property real fontSize: theme.body
  readonly property color tone: danger ? theme.urgent : (primary ? theme.accent : theme.foreground)

  signal clicked()

  implicitWidth: row.implicitWidth + theme.space(22)
  implicitHeight: Math.max(theme.space(28), label.implicitHeight + theme.space(12))
  opacity: enabled ? 1 : 0.45

  Rectangle {
    anchors.fill: parent
    radius: root.theme.radius
    color: mouse.pressed ? root.theme.pressedFill
      : root.selected ? root.theme.selectedFill
      : mouse.containsMouse ? root.theme.hoverFill : "transparent"
    border.width: root.primary || root.danger ? root.theme.borderWidth : root.theme.borderWidth
    border.color: root.primary || root.danger ? root.tone : root.theme.border
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(6)
    Glyph {
      visible: root.icon !== ""
      name: root.busy ? "refresh" : root.icon
      size: root.fontSize + 2
      color: root.tone
      font.family: root.theme.font
      anchors.verticalCenter: parent.verticalCenter
      RotationAnimation on rotation {
        running: root.busy
        from: 0; to: 360; duration: 1100; loops: Animation.Infinite
      }
    }
    Text {
      id: label
      text: root.text
      color: root.tone
      font.family: root.theme.font
      font.pixelSize: root.fontSize
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    enabled: !root.busy
    onClicked: root.clicked()
  }
}
