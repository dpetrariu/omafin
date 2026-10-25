import QtQuick
import "../components"

// The title strip above a view: an optional way back, a title, a line of
// detail and the view's own actions on the right.
Item {
  id: root

  required property var theme
  property string title: ""
  property string subtitle: ""
  property bool showBack: false
  property var actions: []        // [{ id, label, icon, danger }]
  property Item extra: null

  signal back()
  signal actionTriggered(string id, Item button)

  implicitHeight: theme.space(subtitle !== "" ? 70 : 56)

  IconButton {
    id: backButton
    visible: root.showBack
    theme: root.theme
    anchors.left: parent.left
    anchors.leftMargin: root.theme.space(10)
    anchors.verticalCenter: titles.verticalCenter
    icon: "back"
    tooltip: "Back (Esc)"
    onClicked: root.back()
  }

  Column {
    id: titles
    anchors.left: root.showBack ? backButton.right : parent.left
    anchors.leftMargin: root.theme.space(root.showBack ? 6 : 18)
    anchors.right: actionRow.left
    anchors.rightMargin: root.theme.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.theme.space(3)
    Text {
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.display * 0.8
    }
    Text {
      visible: root.subtitle !== ""
      width: parent.width
      text: root.subtitle
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
  }

  Row {
    id: actionRow
    anchors.right: parent.right
    anchors.rightMargin: root.theme.space(16)
    anchors.verticalCenter: parent.verticalCenter
    spacing: root.theme.space(6)
    Repeater {
      model: root.actions
      delegate: TextButton {
        required property var modelData
        theme: root.theme
        text: modelData.label
        icon: modelData.icon || ""
        danger: modelData.danger === true
        primary: modelData.primary === true
        selected: modelData.selected === true
        fontSize: root.theme.small
        onClicked: root.actionTriggered(modelData.id, this)
      }
    }
  }
}
