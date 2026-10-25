import QtQuick
import qs.Ui

// Where you are in the library. Sections are rows of icon, label and an
// optional count; collapsed, only the icons stay and labels move to tooltips.
// Holding Alt names each row's number, read from the same list the keys use.
Item {
  id: root

  required property var theme
  required property var sections   // [{ id, label, icon, count, group }]
  property string current: ""
  property bool collapsed: false
  property bool showNumbers: false
  property string footerTitle: ""
  property string footerDetail: ""
  property string footerIcon: "server"
  property bool footerAttention: false

  signal picked(string id)
  signal footerClicked()

  implicitWidth: collapsed ? theme.space(52) : theme.space(208)

  Rectangle {
    anchors.right: parent.right
    width: root.theme.borderWidth
    height: parent.height
    color: root.theme.border
  }

  Flickable {
    id: flick
    anchors { top: parent.top; left: parent.left; right: parent.right; bottom: footer.top }
    anchors.rightMargin: root.theme.borderWidth
    contentHeight: column.implicitHeight + root.theme.space(16)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      y: root.theme.space(8)
      x: root.theme.space(6)
      width: parent.width - root.theme.space(12)
      spacing: root.theme.space(1)

      Repeater {
        model: root.sections
        delegate: Item {
          id: entry
          required property var modelData
          required property int index
          readonly property bool active: root.current === modelData.id
          readonly property bool groupStart: index > 0 && modelData.group !== root.sections[index - 1].group
          width: column.width
          height: root.theme.space(32) + (groupStart ? root.theme.space(13) : 0)

          Rectangle {
            visible: entry.groupStart
            x: root.theme.space(6)
            y: root.theme.space(6)
            width: parent.width - root.theme.space(12)
            height: root.theme.borderWidth
            color: root.theme.border
          }

          Rectangle {
            id: surface
            anchors.bottom: parent.bottom
            width: parent.width
            height: root.theme.space(32)
            radius: root.theme.radius
            color: entry.active ? root.theme.selectedFill : (mouse.containsMouse ? root.theme.hoverFill : "transparent")

            // The active row also carries a bar, so it is not told by colour alone.
            Rectangle {
              visible: entry.active
              width: root.theme.space(3)
              height: parent.height - root.theme.space(12)
              anchors.verticalCenter: parent.verticalCenter
              radius: width / 2
              color: root.theme.accent
            }

            Glyph {
              id: icon
              x: root.collapsed ? (parent.width - width) / 2 : root.theme.space(12)
              width: root.theme.space(18)
              anchors.verticalCenter: parent.verticalCenter
              name: entry.modelData.icon
              size: root.theme.icon
              color: entry.active ? root.theme.accent : root.theme.foreground
              font.family: root.theme.font
              opacity: entry.active ? 1 : 0.85
            }

            Text {
              visible: !root.collapsed
              anchors.left: icon.right
              anchors.leftMargin: root.theme.space(10)
              anchors.right: suffix.left
              anchors.rightMargin: root.theme.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: entry.modelData.label
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.theme.foreground
              font.family: root.theme.font
              font.pixelSize: root.theme.body
              font.bold: entry.active
            }

            Text {
              id: suffix
              visible: !root.collapsed
              anchors.right: parent.right
              anchors.rightMargin: root.theme.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.showNumbers && entry.index < 10 ? String((entry.index + 1) % 10)
                : (entry.modelData.count !== undefined && entry.modelData.count !== null && entry.modelData.count !== "" ? String(entry.modelData.count) : "")
              textFormat: Text.PlainText
              color: root.showNumbers ? root.theme.accent : root.theme.dim
              font.family: root.theme.font
              font.pixelSize: root.theme.small
            }

            Text {
              visible: root.collapsed && root.showNumbers && entry.index < 10
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: root.theme.space(2)
              text: String((entry.index + 1) % 10)
              color: root.theme.accent
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
            }

            MouseArea {
              id: mouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.picked(entry.modelData.id)
            }

            PanelToolTip {
              visible: root.collapsed && mouse.containsMouse
              text: entry.modelData.label
            }
          }
        }
      }
    }
  }

  // The account and server, and the way into Settings.
  Item {
    id: footer
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    anchors.rightMargin: root.theme.borderWidth
    height: root.theme.space(52)

    Rectangle {
      width: parent.width
      height: root.theme.borderWidth
      color: root.theme.border
    }

    Rectangle {
      anchors.fill: parent
      anchors.margins: root.theme.space(6)
      radius: root.theme.radius
      color: footerMouse.containsMouse ? root.theme.hoverFill : "transparent"
    }

    Glyph {
      id: footerGlyph
      x: root.collapsed ? (parent.width - width) / 2 : root.theme.space(18)
      anchors.verticalCenter: parent.verticalCenter
      name: root.footerIcon
      size: root.theme.icon
      color: root.footerAttention ? root.theme.urgent : root.theme.dim
      font.family: root.theme.font
    }

    Column {
      visible: !root.collapsed
      anchors.left: footerGlyph.right
      anchors.leftMargin: root.theme.space(10)
      anchors.right: parent.right
      anchors.rightMargin: root.theme.space(10)
      anchors.verticalCenter: parent.verticalCenter
      Text {
        width: parent.width
        text: root.footerTitle
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Text {
        width: parent.width
        text: root.footerDetail
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.footerAttention ? root.theme.urgent : root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
      }
    }

    MouseArea {
      id: footerMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.footerClicked()
    }

    PanelToolTip {
      visible: root.collapsed && footerMouse.containsMouse
      text: root.footerTitle + "\n" + root.footerDetail
    }
  }
}
