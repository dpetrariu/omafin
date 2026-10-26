import QtQuick
import QtQuick.Controls as QQC

// A page of card rows under an optional header: Home, a details page and
// search results are all this. The keyboard moves between rows (j/k) and
// along them (h/l); the header counts as the row above the first when it
// asks to (a details page's Play button).
Item {
  id: root

  required property var theme
  required property var service
  // [{ key, title, items, shape, action, episodeTitles, cardWidth }]
  property var rows: []
  property Component header: null
  property bool headerFocusable: false
  property int rowIndex: -1
  // Until the keyboard or the mouse picks a row, the page starts at its
  // header when it has one and at the first row otherwise.
  property bool moved: false
  // Where the cursor is on each row, by the row's key: marking a card
  // rebuilds the rows, and the cursor must stay on that card.
  property var cursors: ({})
  onHeaderFocusableChanged: if (!moved) rowIndex = headerFocusable ? -1 : 0
  Component.onCompleted: if (!moved) rowIndex = headerFocusable ? -1 : 0
  readonly property bool headerActive: headerFocusable && rowIndex < 0
  property real topPadding: theme.space(16)
  property alias flickable: flick
  property alias wheel: wheel
  readonly property var headerItem: headerLoader.item

  signal opened(var item, var row)
  signal played(var item, var row)
  signal menuRequested(var item, Item anchor, real x, real y)
  signal actionClicked(var row)

  readonly property var visibleRows: rows.filter(function(r) { return r && r.items && r.items.length > 0 })

  function rowItem(i) {
    return i >= 0 && i < repeater.count ? repeater.itemAt(i) : null
  }

  // The card the keyboard is on, or null on the header.
  function currentItem() {
    var row = rowItem(rowIndex)
    return row ? row.currentItem : null
  }
  // The card on screen, for a menu to open beside it.
  function currentCard() {
    if (rowIndex < 0) return null
    var row = rowItem(rowIndex)
    return row ? row.currentCard() : null
  }
  function currentRow() {
    return rowIndex >= 0 && rowIndex < visibleRows.length ? visibleRows[rowIndex] : null
  }

  function moveRow(delta) {
    moved = true
    var lowest = headerFocusable ? -1 : 0
    var next = Math.max(lowest, Math.min(visibleRows.length - 1, rowIndex + delta))
    if (next === rowIndex) {
      if (delta < 0) flick.contentY = 0
      return
    }
    rowIndex = next
    reveal()
  }

  function moveAlong(delta) {
    var row = rowItem(rowIndex)
    if (!row || !row.items) return
    row.currentIndex = Math.max(0, Math.min(row.items.length - 1, row.currentIndex + delta))
  }

  function reveal() {
    wheel.stop()
    if (rowIndex < 0) { flick.contentY = 0; return }
    var row = rowItem(rowIndex)
    if (!row) return
    var top = row.y + column.y
    var bottom = top + row.height
    if (top < flick.contentY) flick.contentY = Math.max(0, top - theme.space(12))
    else if (bottom > flick.contentY + flick.height) flick.contentY = Math.min(flick.contentHeight - flick.height, bottom - flick.height + theme.space(12))
  }

  // Keys the page answers; the view handles the rest.
  function handleKey(id) {
    switch (id) {
    case "up": moveRow(-1); return true
    case "down": moveRow(1); return true
    case "left": if (rowIndex >= 0) moveAlong(-1); return true
    case "right": if (rowIndex >= 0) moveAlong(1); return true
    case "pageDown": moveRow(3); return true
    case "pageUp": moveRow(-3); return true
    case "first":
      if (rowIndex >= 0) { var r = rowItem(rowIndex); if (r) r.currentIndex = 0 }
      return true
    case "last":
      if (rowIndex >= 0) { var l = rowItem(rowIndex); if (l && l.items) l.currentIndex = l.items.length - 1 }
      return true
    }
    return false
  }

  onVisibleRowsChanged: if (visibleRows.length > 0 && rowIndex >= visibleRows.length) rowIndex = visibleRows.length - 1

  function cursorFor(row) {
    if (!row || !row.items) return 0
    var kept = row.key !== undefined ? cursors[row.key] : undefined
    return Math.max(0, Math.min(row.items.length - 1, kept !== undefined ? kept : (row.startIndex || 0)))
  }

  WheelScroller {
    id: wheel
    flickable: flick
    notch: root.theme.space(360)
    // Sideways gestures go to the row under the pointer, which glides and
    // stretches on its own.
    rowAt: function(y) {
      for (var i = 0; i < repeater.count; i++) {
        var row = repeater.itemAt(i)
        if (!row) continue
        var p = row.mapToItem(root, 0, 0)
        if (y >= p.y && y < p.y + row.height) return row.wheel
      }
      return null
    }
  }

  Flickable {
    id: flick
    anchors.fill: parent
    contentHeight: column.y + column.implicitHeight + root.theme.space(32)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}
    // Keyboard moves glide; the wheel moves at once.
    Behavior on contentY { enabled: !flick.moving && !wheel.active; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    Loader {
      id: headerLoader
      width: flick.width
      sourceComponent: root.header
    }

    Column {
      id: column
      y: headerLoader.height + root.topPadding
      width: flick.width
      spacing: root.theme.space(22)

      // A count, not the rows themselves: new data then updates each row in
      // place, instead of rebuilding them all (which emptied the page for a
      // moment and threw it back to the top).
      Repeater {
        id: repeater
        model: root.visibleRows.length
        delegate: CardRow {
          id: rowDelegate
          required property int index
          readonly property var modelData: root.visibleRows[index] || ({ items: [] })
          readonly property string rowKey: modelData.key !== undefined ? String(modelData.key) : ""
          // Another row now in this place (a season switched): its own cursor.
          onRowKeyChanged: currentIndex = root.cursorFor(modelData)
          theme: root.theme
          service: root.service
          title: modelData.title || ""
          action: modelData.action || ""
          items: modelData.items
          shape: modelData.shape || "poster"
          cardWidth: modelData.cardWidth || root.theme.space((modelData.shape || "poster") === "landscape" ? 280 : 150)
          episodeTitles: modelData.episodeTitles === true
          active: index === root.rowIndex
          Component.onCompleted: currentIndex = root.cursorFor(modelData)
          onCurrentIndexChanged: if (modelData.key !== undefined) root.cursors[modelData.key] = currentIndex
          onOpened: function(item) { root.moved = true; root.rowIndex = index; root.opened(item, modelData) }
          onPlayed: function(item) { root.moved = true; root.rowIndex = index; root.played(item, modelData) }
          onMenuRequested: function(item, anchor, x, y) { root.moved = true; root.rowIndex = index; root.menuRequested(item, anchor, x, y) }
          onActionClicked: root.actionClicked(modelData)
        }
      }
    }
  }
}
