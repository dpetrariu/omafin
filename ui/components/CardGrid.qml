import QtQuick
import QtQuick.Controls as QQC

// A library as a grid of cards that loads more as it nears the end. The
// keyboard cursor is kept here; hover does not move it.
Item {
  id: root

  required property var theme
  required property var service
  property var items: []
  property int total: 0
  property bool loading: false
  property string shape: "poster"
  property real cardWidth: theme.space(150)
  property int currentIndex: 0
  property Component header: null

  signal opened(var item, int index)
  signal played(var item, int index)
  signal menuRequested(var item, Item anchor, real x, real y)
  signal needMore()

  readonly property var currentItem: currentIndex >= 0 && currentIndex < items.length ? items[currentIndex] : null
  readonly property int columns: Math.max(1, Math.floor((grid.width - grid.leftMargin - grid.rightMargin + gap) / (cardWidth + gap)))
  readonly property real gap: theme.space(18)
  // Spread the spare width over the columns so the grid fills the row.
  readonly property real cellWidth: (grid.width - grid.leftMargin - grid.rightMargin) / columns
  readonly property real cardDrawWidth: cellWidth - gap
  readonly property real cardHeight: Math.round(cardDrawWidth / (shape === "landscape" ? 16 / 9 : shape === "square" ? 1 : 2 / 3))
    + theme.small + theme.caption + theme.space(14)

  function currentCard() {
    var cell = grid.itemAtIndex(currentIndex)
    return cell ? cell.children[0] : null
  }

  function move(delta) {
    if (items.length === 0) return
    currentIndex = Math.max(0, Math.min(items.length - 1, currentIndex + delta))
    grid.positionViewAtIndex(currentIndex, GridView.Contain)
    if (currentIndex >= items.length - columns * 3) needMore()
  }

  function handleKey(id) {
    switch (id) {
    case "left": move(-1); return true
    case "right": move(1); return true
    case "up": move(-columns); return true
    case "down": move(columns); return true
    case "pageDown": move(columns * Math.max(1, Math.floor(grid.height / grid.cellHeight))); return true
    case "pageUp": move(-columns * Math.max(1, Math.floor(grid.height / grid.cellHeight))); return true
    case "first": move(-items.length); return true
    case "last": move(items.length); return true
    }
    return false
  }

  WheelScroller {
    flickable: grid
    notch: root.cardHeight * 0.8
  }

  GridView {
    id: grid
    anchors.fill: parent
    leftMargin: root.theme.space(24)
    rightMargin: root.theme.space(24) - root.gap
    topMargin: root.theme.space(4)
    bottomMargin: root.theme.space(24)
    cellWidth: root.cellWidth
    cellHeight: root.cardHeight + root.gap
    model: root.items
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    cacheBuffer: Math.max(0, root.cardHeight * 3)
    header: root.header
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    onContentYChanged: if (contentHeight > 0 && contentY + height > contentHeight - root.cardHeight * 3) root.needMore()

    delegate: Item {
      required property var modelData
      required property int index
      width: grid.cellWidth
      height: grid.cellHeight
      MediaCard {
        theme: root.theme
        service: root.service
        item: modelData
        shape: root.shape
        width: root.cardDrawWidth
        current: index === root.currentIndex && root.activeFocusHint
        onClicked: { root.currentIndex = index; root.opened(modelData, index) }
        onPlayClicked: { root.currentIndex = index; root.played(modelData, index) }
        onMenuRequested: function(anchor, x, y) { root.currentIndex = index; root.menuRequested(modelData, anchor, x, y) }
      }
    }

    footer: Item {
      width: grid.width
      height: root.loading ? root.theme.space(48) : 0
      Text {
        anchors.centerIn: parent
        visible: root.loading
        text: "Loading…"
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }
  }

  // The cursor shows once the keyboard has been used, as in the rows.
  property bool activeFocusHint: true
}
