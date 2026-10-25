import QtQuick
import qs.Ui

// An icon on the shared hover surface. Icon-only actions always say what they
// do in a tooltip.
Item {
  id: root

  required property var theme
  property string icon: ""
  property string tooltip: ""
  property color color: theme.foreground
  property bool selected: false
  property bool busy: false
  property bool attention: false
  property real iconSize: theme.icon
  property real size: Math.max(theme.space(26), iconSize + theme.space(10))

  signal clicked()

  implicitWidth: size
  implicitHeight: size
  opacity: enabled ? 1 : 0.4

  Rectangle {
    anchors.fill: parent
    anchors.margins: root.theme.space(1)
    radius: root.theme.radius
    color: mouse.pressed ? root.theme.pressedFill
      : root.selected ? root.theme.selectedFill
      : mouse.containsMouse ? root.theme.hoverFill : "transparent"
    border.width: root.attention ? root.theme.borderWidth : 0
    border.color: root.theme.accent
  }

  Glyph {
    id: glyph
    anchors.centerIn: parent
    name: root.icon
    size: root.iconSize
    color: root.attention ? root.theme.accent : root.color
    font.family: root.theme.font
    RotationAnimation on rotation {
      running: root.busy
      from: 0; to: 360; duration: 1100; loops: Animation.Infinite
      onRunningChanged: if (!running) glyph.rotation = 0
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: mouse.containsMouse && root.tooltip !== ""
    text: root.tooltip
  }
}
