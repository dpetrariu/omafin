import QtQuick
import QtQuick.Controls as QQC
import "../keys/Keymap.js" as Keymap

// Every key, grouped, drawn from the same table that binds them.
Item {
  id: root
  required property var theme
  signal closed()
  z: 450

  Rectangle {
    anchors.fill: parent
    color: root.theme.alpha(root.theme.background, 0.97)
    MouseArea { anchors.fill: parent; onClicked: root.closed() }
  }

  Flickable {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(1040))
    height: Math.min(parent.height - root.theme.space(48), flow.implicitHeight + root.theme.space(60))
    contentHeight: flow.implicitHeight + root.theme.space(60)
    clip: true
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Text {
      id: heading
      text: "Keyboard"
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.heading
    }

    Flow {
      id: flow
      anchors.top: heading.bottom
      anchors.topMargin: root.theme.space(18)
      width: parent.width
      spacing: root.theme.space(24)
      Repeater {
        model: Keymap.helpGroups()
        delegate: Column {
          required property var modelData
          width: root.theme.space(320)
          spacing: root.theme.space(6)
          Text {
            text: modelData.title
            color: root.theme.accent
            font.family: root.theme.font
            font.pixelSize: root.theme.body
            bottomPadding: root.theme.space(2)
          }
          Repeater {
            model: modelData.rows
            delegate: Row {
              required property var modelData
              spacing: root.theme.space(12)
              Text {
                width: root.theme.space(118)
                horizontalAlignment: Text.AlignRight
                text: modelData.keys
                color: root.theme.foreground
                font.family: root.theme.font
                font.pixelSize: root.theme.small
                elide: Text.ElideLeft
              }
              Text {
                width: root.theme.space(190)
                text: modelData.label
                color: root.theme.dim
                wrapMode: Text.Wrap
                font.family: root.theme.font
                font.pixelSize: root.theme.small
              }
            }
          }
        }
      }
    }
  }
}
