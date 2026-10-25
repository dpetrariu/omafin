import QtQuick
import qs.Ui

// A switch that applies at once, its label, and an optional line saying
// what it means.
Item {
  id: root
  required property var theme
  property bool checked: false
  property string text: ""
  property string detail: ""
  signal toggled()

  width: parent ? parent.width : 0
  implicitHeight: Math.max(toggle.implicitHeight, labels.implicitHeight)
  opacity: enabled ? 1 : 0.45

  ToggleSwitch {
    id: toggle
    anchors.verticalCenter: labels.verticalCenter
    checked: root.checked
    interactive: root.enabled
    onToggled: root.toggled()
  }
  Column {
    id: labels
    anchors.left: toggle.right
    anchors.leftMargin: root.theme.space(10)
    anchors.right: parent.right
    Text {
      width: parent.width
      wrapMode: Text.Wrap
      text: root.text
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    Text {
      visible: root.detail !== ""
      width: parent.width
      wrapMode: Text.Wrap
      text: root.detail
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.caption
    }
  }
}
