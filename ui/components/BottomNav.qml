import QtQuick

// Tabs along the bottom of a phone-width window: the four places used most,
// and More for the rest. The active tab carries a bar, not colour alone.
Item {
  id: root

  required property var theme
  property var sections: []
  property string current: ""
  readonly property var main: sections.filter(function(s) { return ["home", "favorites"].concat(root.sections.filter(function(s) { return s.group === "libraries" }).slice(0, 2).map(function(s) { return s.id })).indexOf(s.id) >= 0 })
  readonly property var rest: sections.filter(function(s) { return ["home", "favorites"].concat(root.sections.filter(function(s) { return s.group === "libraries" }).slice(0, 2).map(function(s) { return s.id })).indexOf(s.id) < 0 })
  readonly property bool restActive: rest.some(function(s) { return s.id === root.current })

  signal picked(string id)
  signal moreRequested(Item item, var rest)

  implicitHeight: theme.space(52)

  Rectangle {
    width: parent.width
    height: root.theme.borderWidth
    color: root.theme.border
  }

  Row {
    anchors.fill: parent
    anchors.topMargin: root.theme.borderWidth
    Repeater {
      model: root.main.concat([{ id: "_more", label: "More", icon: "moreHorizontal" }])
      delegate: Item {
        id: tab
        required property var modelData
        readonly property bool active: modelData.id === "_more" ? root.restActive : modelData.id === root.current
        width: parent.width / (root.main.length + 1)
        height: parent.height
        Rectangle {
          visible: tab.active
          anchors.top: parent.top
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width * 0.4
          height: root.theme.space(2)
          color: root.theme.accent
        }
        Column {
          anchors.centerIn: parent
          spacing: root.theme.space(2)
          Glyph {
            anchors.horizontalCenter: parent.horizontalCenter
            name: tab.modelData.icon
            size: root.theme.icon + 2
            color: tab.active ? root.theme.accent : root.theme.foreground
            font.family: root.theme.font
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: tab.modelData.label
            color: tab.active ? root.theme.foreground : root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (tab.modelData.id === "_more") root.moreRequested(tab, root.rest)
            else root.picked(tab.modelData.id)
          }
        }
      }
    }
  }
}
