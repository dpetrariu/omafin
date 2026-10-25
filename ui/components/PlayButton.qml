import QtQuick
import "../lib/Format.js" as Format

// The one action a page is for: "Play", or "Resume S1 · E3" with how far
// you got filled into the button, as Fladder draws it.
Item {
  id: root

  required property var theme
  property var item: null
  property string label: Format.playLabel(item)
  property bool current: false
  readonly property real progress: Format.progress(item)

  signal clicked()

  implicitWidth: row.implicitWidth + theme.space(34)
  implicitHeight: theme.space(40)

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: height / 2
    color: mouse.pressed ? Qt.darker(root.theme.accent, 1.2) : root.theme.accent
    clip: true
    // Progress as a darker band from the left.
    Rectangle {
      visible: root.progress > 0
      width: parent.width * root.progress
      height: parent.height
      color: Qt.rgba(0, 0, 0, 0.22)
    }
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: "white"
      opacity: mouse.containsMouse ? 0.12 : 0
    }
  }

  Rectangle {
    visible: root.current
    anchors.fill: parent
    anchors.margins: -root.theme.space(4)
    radius: height / 2
    color: "transparent"
    border.width: root.theme.space(2)
    border.color: root.theme.foreground
  }

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(8)
    Glyph {
      name: "play"
      size: root.theme.subtitle + 2
      color: root.theme.background
      font.family: root.theme.font
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      text: root.label
      textFormat: Text.PlainText
      color: root.theme.background
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      font.bold: true
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
