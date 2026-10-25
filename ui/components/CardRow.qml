import QtQuick
import QtQuick.Controls as QQC
import "../views"

// A titled row of cards that scrolls sideways. The view that holds it owns
// the keyboard; the row only shows which card is current and scrolls it
// into sight.
Item {
  id: root

  required property var theme
  required property var service
  property string title: ""
  property string action: ""      // "See all" link text, empty for none
  property var items: []
  property string shape: "poster"
  property real cardWidth: theme.space(shape === "landscape" ? 280 : 150)
  property bool active: false
  property int currentIndex: 0
  property bool episodeTitles: false

  signal opened(var item, int index)
  signal played(var item, int index)
  signal menuRequested(var item, Item anchor, real x, real y)
  signal actionClicked()

  onItemsChanged: {
    var x = list.contentX
    list.model = items
    list.contentX = x
    keepX.x = x
    keepX.restart()
  }
  Component.onCompleted: list.model = items
  // The view lays out on its next frame; put the scroll back after it.
  Timer {
    id: keepX
    property real x: 0
    interval: 0
    onTriggered: list.contentX = Math.max(-list.leftMargin, Math.min(x, list.contentWidth - list.width + list.rightMargin))
  }

  readonly property var currentItem: items && currentIndex >= 0 && currentIndex < items.length ? items[currentIndex] : null
  function currentCard() { return list.itemAtIndex(currentIndex) }
  function scrollBy(dx) {
    var start = -list.leftMargin
    var end = Math.max(start, list.contentWidth - list.width + list.rightMargin)
    list.cancelFlick()
    list.contentX = Math.max(start, Math.min(end, list.contentX + dx))
  }

  width: parent ? parent.width : 0
  implicitHeight: heading.height + list.height + theme.space(6)

  onCurrentIndexChanged: if (active) list.positionViewAtIndex(currentIndex, ListView.Contain)
  onActiveChanged: if (active) list.positionViewAtIndex(currentIndex, ListView.Contain)

  SectionTitle {
    id: heading
    theme: root.theme
    visible: root.title !== ""
    height: visible ? implicitHeight : 0
    x: root.theme.space(24)
    width: parent.width - root.theme.space(48)
    text: root.title
    action: root.action
    onActionClicked: root.actionClicked()
  }

  ListView {
    id: list
    anchors.top: heading.bottom
    anchors.topMargin: root.theme.space(8)
    width: parent.width
    height: root.cardHeight + root.theme.space(8)
    orientation: ListView.Horizontal
    spacing: root.theme.space(14)
    leftMargin: root.theme.space(24)
    rightMargin: root.theme.space(24)
    clip: false
    // Set by hand, keeping the scroll: new data for the same row must not
    // throw it back to its first card.
    model: []
    boundsBehavior: Flickable.StopAtBounds
    highlightFollowsCurrentItem: false
    cacheBuffer: root.cardWidth * 4
    QQC.ScrollBar.horizontal: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

    delegate: MediaCard {
      required property var modelData
      required property int index
      theme: root.theme
      service: root.service
      item: modelData
      shape: root.shape
      width: root.cardWidth
      current: root.active && index === root.currentIndex
      episodeTitles: root.episodeTitles
      onClicked: { root.currentIndex = index; root.opened(modelData, index) }
      onPlayClicked: { root.currentIndex = index; root.played(modelData, index) }
      onMenuRequested: function(anchor, x, y) { root.currentIndex = index; root.menuRequested(modelData, anchor, x, y) }
    }

    // The page's WheelScroller handles the wheel; the row scrolls only
    // sideways, by drag or a sideways swipe.
    interactive: true
  }

  // The height of one card with its two lines.
  readonly property real cardHeight: Math.round(cardWidth / (shape === "landscape" ? 16 / 9 : shape === "square" ? 1 : 2 / 3))
    + theme.small + theme.caption + theme.space(18)

  // Step buttons for the mouse, like Fladder's: one page sideways.
  IconButton {
    theme: root.theme
    visible: hover.hovered && list.contentX > -list.leftMargin + 4
    anchors.left: parent.left
    anchors.leftMargin: root.theme.space(4)
    y: list.y + (root.cardHeight - height) / 2 - root.theme.space(20)
    icon: "chevronLeft"
    tooltip: "Scroll left"
    onClicked: list.contentX = Math.max(-list.leftMargin, list.contentX - list.width * 0.6)
  }
  IconButton {
    theme: root.theme
    visible: hover.hovered && list.contentX < list.contentWidth - list.width + list.rightMargin - 4
    anchors.right: parent.right
    anchors.rightMargin: root.theme.space(4)
    y: list.y + (root.cardHeight - height) / 2 - root.theme.space(20)
    icon: "chevronRight"
    tooltip: "Scroll right"
    onClicked: list.contentX = Math.min(list.contentWidth - list.width + list.rightMargin, list.contentX + list.width * 0.6)
  }
  HoverHandler { id: hover }
}
