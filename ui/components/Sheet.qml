import QtQuick

// A modal surface over the window: a scrim, a panel, a title and whatever the
// caller puts inside. Escape and a click on the scrim dismiss it (App routes
// Escape here through the "dialog" key context).
Item {
  id: root

  required property var theme
  property string title: ""
  property string subtitle: ""
  property real preferredWidth: theme.space(460)
  property bool opened: false
  default property alias content: body.data

  signal dismissed()

  anchors.fill: parent
  visible: opened
  z: 500

  function close() { opened = false; dismissed() }

  Rectangle {
    anchors.fill: parent
    color: root.theme.alpha(root.theme.background, 0.72)
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onClicked: root.close()
      onWheel: function(wheel) { wheel.accepted = true }
    }
  }

  Rectangle {
    id: panel
    anchors.centerIn: parent
    width: Math.min(root.preferredWidth, root.width - root.theme.space(48))
    height: Math.min(header.height + body.childrenRect.height + root.theme.space(36), root.height - root.theme.space(48))
    color: root.theme.popupBackground
    border.width: root.theme.borderWidth
    border.color: root.theme.popupBorder
    radius: root.theme.radius
    clip: true

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    Column {
      id: header
      x: root.theme.space(18)
      y: root.theme.space(16)
      width: parent.width - root.theme.space(36)
      spacing: root.theme.space(4)
      Text {
        width: parent.width
        text: root.title
        textFormat: Text.PlainText
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        visible: root.subtitle !== ""
        width: parent.width
        text: root.subtitle
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }

    Item {
      id: body
      x: root.theme.space(18)
      anchors.top: header.bottom
      anchors.topMargin: root.theme.space(14)
      width: parent.width - root.theme.space(36)
      height: childrenRect.height
    }
  }
}
