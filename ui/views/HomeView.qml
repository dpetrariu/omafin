import QtQuick
import "../components"
import "../lib/Format.js" as Format
import "../lib/Items.js" as Items

// Home: what you are watching first, then what comes next, then what is
// new in each library. The hero shows one of the things you are watching;
// h and l on it step through them.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "browse"
  readonly property bool typing: false
  property var home: null
  property bool loading: false
  property string error: ""
  property int heroIndex: 0
  readonly property var heroItems: home ? home.resume.concat(home.nextUp).slice(0, 10) : []
  readonly property var hero: heroItems.length > 0 ? heroItems[Math.min(heroIndex, heroItems.length - 1)] : null
  readonly property string statusText: loading ? "Loading…" : home ? (home.resume.length > 0 ? Format.count(home.resume.length, "film or episode", "films and episodes") + " in progress" : "") : ""

  signal openItem(var item)
  signal playItem(var item, bool restart)
  signal menuItem(var item, Item anchor, real x, real y)
  signal openGrid(var entry)

  Component.onCompleted: reload()

  Connections {
    target: root.service
    function onLibraryRevisionChanged() { root.reload() }
  }

  // Fresh rows every two minutes while the window is open, like Fladder.
  Timer {
    interval: 120000
    repeat: true
    running: root.service.windowOpen
    onTriggered: root.reload()
  }

  function reload() {
    if (loading) return
    loading = true
    service.call("home", {}, function(result, error) {
      if (!root) return
      root.loading = false
      root.error = error ? error.message : ""
      if (!error) root.home = result
    })
  }

  readonly property var rows: {
    if (!home) return []
    var out = [
      { key: "resume", title: "Continue watching", items: home.resume, shape: "landscape" },
      { key: "nextUp", title: "Next up", items: home.nextUp, shape: "landscape" }
    ]
    for (var i = 0; i < home.latest.length; i++) {
      var r = home.latest[i]
      out.push({ key: "latest:" + r.viewId, title: "Recently added in " + r.title, items: r.items, shape: "poster",
        action: "See all", viewId: r.viewId, viewTitle: r.title, collectionType: r.collectionType })
    }
    return out
  }

  function patch(id, user) {
    if (!home) return
    var next = Object.assign({}, home)
    next.resume = Items.patchUser(home.resume, id, user)
    next.nextUp = Items.patchUser(home.nextUp, id, user)
    next.latest = home.latest.map(function(r) { var c = Object.assign({}, r); c.items = Items.patchUser(r.items, id, user); return c })
    home = next
  }

  // What p, w, f and the menu act on.
  function currentAnchor() {
    return page.currentCard()
  }

  function currentTarget() {
    return page.headerActive ? hero : page.currentItem()
  }

  function handleKey(id) {
    if (page.headerActive && (id === "left" || id === "right")) {
      if (heroItems.length > 0) heroIndex = (heroIndex + (id === "left" ? -1 : 1) + heroItems.length) % heroItems.length
      return
    }
    if (page.handleKey(id)) return
    if (id === "open") {
      var target = currentTarget()
      if (target) openItem(target)
    }
  }

  BrowsePage {
    id: page
    anchors.fill: parent
    theme: root.theme
    service: root.service
    rows: root.rows
    headerFocusable: root.hero !== null
    topPadding: root.theme.space(root.hero ? 4 : 20)
    header: root.hero ? heroComponent : null
    onOpened: function(item) { root.openItem(item) }
    onPlayed: function(item) { root.playItem(item, false) }
    onMenuRequested: function(item, anchor, x, y) { root.menuItem(item, anchor, x, y) }
    onActionClicked: function(row) {
      root.openGrid({ kind: "grid", title: "Recently added in " + row.viewTitle, parentId: row.viewId,
        types: row.collectionType === "tvshows" ? "Episode" : Format.viewTypes(row.collectionType), sort: "added", descending: true })
    }
  }

  Component {
    id: heroComponent
    Item {
      id: heroBox
      width: parent ? parent.width : 0
      height: Math.max(root.theme.space(300), Math.min(root.theme.space(460), root.height * 0.52))
      readonly property var item: root.hero

      Backdrop {
        anchors.fill: parent
        theme: root.theme
        service: root.service
        image: heroBox.item && heroBox.item.images ? heroBox.item.images.backdrop || heroBox.item.images.thumb : null
        requestWidth: Math.min(2560, heroBox.width * 1.25)
      }

      Column {
        anchors.left: parent.left
        anchors.leftMargin: root.theme.space(32)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.theme.space(18)
        width: Math.min(parent.width * 0.6, root.theme.space(620))
        spacing: root.theme.space(10)

        Text {
          text: heroBox.item && heroBox.item.user && heroBox.item.user.position > 0 ? "CONTINUE WATCHING" : "NEXT UP"
          color: root.theme.accent
          font.family: root.theme.font
          font.pixelSize: root.theme.caption
          font.bold: true
          font.letterSpacing: 1.5
        }
        Image {
          id: logo
          visible: status === Image.Ready
          width: Math.min(parent.width, root.theme.space(380))
          height: root.theme.space(110)
          fillMode: Image.PreserveAspectFit
          horizontalAlignment: Image.AlignLeft
          source: heroBox.item && heroBox.item.images ? root.service.imageUrl(heroBox.item.images.logo, "Logo", 600) : ""
          asynchronous: true
        }
        Text {
          visible: logo.status !== Image.Ready
          width: parent.width
          text: Format.cardTitle(heroBox.item)
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.display
          font.bold: true
        }
        Text {
          visible: !!heroBox.item && heroBox.item.type === "Episode"
          width: parent.width
          text: heroBox.item ? Format.episodeCode(heroBox.item) + "  " + (heroBox.item.name || "") : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.subtitle
        }
        Text {
          width: parent.width
          text: [Format.metaLine(heroBox.item), Format.minutesLeft(heroBox.item)].filter(function(s) { return s !== "" }).join("  ·  ")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        Text {
          width: parent.width
          visible: text !== ""
          text: heroBox.item && heroBox.item.overview ? heroBox.item.overview : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          color: root.theme.foreground
          opacity: 0.85
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          lineHeight: 1.2
        }
        Row {
          spacing: root.theme.space(8)
          PlayButton {
            theme: root.theme
            item: heroBox.item
            current: page.headerActive
            onClicked: root.playItem(heroBox.item, false)
          }
          TextButton {
            theme: root.theme
            text: "Details"
            icon: "info"
            pill: true
            height: root.theme.space(40)
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.openItem(heroBox.item)
          }
        }
      }

      // Which of the in-progress items this is, and a way to the others.
      Row {
        visible: root.heroItems.length > 1
        anchors.right: parent.right
        anchors.rightMargin: root.theme.space(28)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.theme.space(24)
        spacing: root.theme.space(6)
        IconButton {
          theme: root.theme
          icon: "chevronLeft"
          tooltip: "Previous (h on the banner)"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.heroIndex = (root.heroIndex - 1 + root.heroItems.length) % root.heroItems.length
        }
        Repeater {
          model: root.heroItems.length
          delegate: Rectangle {
            required property int index
            anchors.verticalCenter: parent.verticalCenter
            width: index === root.heroIndex ? root.theme.space(18) : root.theme.space(6)
            height: root.theme.space(6)
            radius: height / 2
            color: index === root.heroIndex ? root.theme.accent : root.theme.faint
            Behavior on width { NumberAnimation { duration: 150 } }
            MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.heroIndex = index }
          }
        }
        IconButton {
          theme: root.theme
          icon: "chevronRight"
          tooltip: "Next (l on the banner)"
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.heroIndex = (root.heroIndex + 1) % root.heroItems.length
        }
      }
    }
  }

  // Nothing to show yet: say why, in words.
  Column {
    anchors.centerIn: parent
    visible: !root.loading && (root.error !== "" || (root.home && root.rows.every(function(r) { return r.items.length === 0 })))
    spacing: root.theme.space(10)
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(460))
    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: root.error ? "cloudOff" : "logo"
      size: root.theme.display * 1.6
      color: root.error ? root.theme.urgent : root.theme.faint
      font.family: root.theme.font
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.error || "Nothing here yet. Films and shows appear once your Jellyfin libraries have them."
      textFormat: Text.PlainText
      color: root.error ? root.theme.urgent : root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      visible: root.error !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      theme: root.theme
      text: "Try again"
      onClicked: root.reload()
    }
  }
}
