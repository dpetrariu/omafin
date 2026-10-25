import QtQuick
import QtQuick.Controls as QQC
// A short list of commands tied to whatever opened it. Rows are plain objects:
// { id, label, icon, shortcut, danger, enabled, separator }. Pointer and
// keyboard share one highlighted row; Escape closes; activating closes first
// and then reports, so the action runs against a settled view.
QQC.Popup {
  id: root

  required property var theme
  property var items: []
  property int highlighted: -1
  // The element the menu belongs to. It stays selected while the menu is up.
  property Item trigger: null

  signal activated(string id)

  padding: theme.space(4)
  modal: false
  focus: true
  closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside

  readonly property real rowHeight: theme.space(28)
  // As wide as its widest row (audio and subtitle names run long), but
  // never wider than the window; longer labels are cut with an ellipsis.
  property real widest: 0
  onItemsChanged: widest = 0
  readonly property real maxWidth: parent ? parent.width - theme.space(16) : theme.space(600)
  readonly property bool hasIcons: items.some(function(i) { return !!i.icon })

  // Open beside `item` at (x, y) in its coordinates, flipping and clamping so
  // it stays inside the window.
  function openAt(item, x, y) {
    if (!item || !parent) return
    var p = item.mapToItem(parent, x, y)
    highlighted = -1
    open()
    place(p.x, p.y)
    contentItem.forceActiveFocus()
  }

  function openBelow(item) {
    trigger = item
    openAt(item, 0, item.height + theme.space(2))
  }

  function place(px, py) {
    var w = implicitWidth
    var h = implicitHeight
    var maxX = parent.width - w - theme.space(4)
    var maxY = parent.height - h - theme.space(4)
    x = Math.max(theme.space(4), Math.min(px, maxX))
    y = py > maxY && py - h > 0 ? py - h : Math.max(theme.space(4), Math.min(py, maxY))
  }

  function move(step) {
    if (items.length === 0) return
    var i = highlighted
    for (var n = 0; n < items.length; n++) {
      i = (i + step + items.length) % items.length
      var item = items[i]
      if (!item.separator && item.enabled !== false) {
        highlighted = i
        return
      }
    }
  }

  function activate(index) {
    var item = items[index]
    if (!item || item.separator || item.enabled === false) return
    close()
    var id = String(item.id)
    Qt.callLater(function() { root.activated(id) })
  }

  background: Rectangle {
    color: root.theme.popupBackground
    border.width: root.theme.borderWidth
    border.color: root.theme.popupBorder
    radius: root.theme.radius
  }

  contentItem: FocusScope {
    implicitWidth: Math.min(root.maxWidth - root.padding * 2, Math.max(root.theme.space(200), root.widest))
    implicitHeight: column.implicitHeight
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Down || event.key === Qt.Key_J || event.key === Qt.Key_Tab) {
        root.move(1); event.accepted = true
      } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K || event.key === Qt.Key_Backtab) {
        root.move(-1); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        root.activate(root.highlighted); event.accepted = true
      }
    }

    Column {
      id: column
      width: parent.width

      Repeater {
        model: root.items
        delegate: Item {
          id: rowItem
          required property var modelData
          required property int index
          width: column.width
          implicitWidth: label.implicitWidth + shortcut.implicitWidth + root.theme.space(root.hasIcons ? 64 : 40)
          height: modelData.separator ? root.theme.space(9) : root.rowHeight
          onImplicitWidthChanged: if (implicitWidth > root.widest) root.widest = implicitWidth
          Component.onCompleted: if (implicitWidth > root.widest) root.widest = implicitWidth

          Rectangle {
            visible: rowItem.modelData.separator === true
            anchors.verticalCenter: parent.verticalCenter
            x: root.theme.space(6)
            width: parent.width - root.theme.space(12)
            height: root.theme.borderWidth
            color: root.theme.border
          }

          Rectangle {
            visible: !rowItem.modelData.separator
            anchors.fill: parent
            radius: root.theme.radius
            color: root.highlighted === rowItem.index ? root.theme.hoverFill : "transparent"
          }

          Glyph {
            visible: !rowItem.modelData.separator && root.hasIcons
            x: root.theme.space(8)
            width: root.theme.space(18)
            anchors.verticalCenter: parent.verticalCenter
            name: rowItem.modelData.icon || ""
            size: root.theme.icon
            font.family: root.theme.font
            color: rowItem.modelData.danger ? root.theme.urgent : root.theme.foreground
            opacity: rowItem.modelData.enabled === false ? 0.4 : 1
          }

          Text {
            id: label
            visible: !rowItem.modelData.separator
            x: root.theme.space(root.hasIcons ? 34 : 10)
            width: Math.min(implicitWidth, parent.width - x - shortcut.width - root.theme.space(20))
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
            text: rowItem.modelData.label || ""
            textFormat: Text.PlainText
            color: rowItem.modelData.danger ? root.theme.urgent : root.theme.foreground
            opacity: rowItem.modelData.enabled === false ? 0.4 : 1
            font.family: root.theme.font
            font.pixelSize: root.theme.body
          }

          Text {
            id: shortcut
            visible: !rowItem.modelData.separator && !!rowItem.modelData.shortcut
            anchors.right: parent.right
            anchors.rightMargin: root.theme.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: rowItem.modelData.shortcut || ""
            textFormat: Text.PlainText
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }

          MouseArea {
            anchors.fill: parent
            enabled: !rowItem.modelData.separator
            hoverEnabled: true
            onEntered: if (rowItem.modelData.enabled !== false) root.highlighted = rowItem.index
            onClicked: root.activate(rowItem.index)
          }
        }
      }
    }
  }
}
