import QtQuick
import "../components"
import "../lib/Format.js" as Format
import "../lib/Items.js" as Items

// Everything that matches, by kind: films, shows, episodes, collections
// and people, each a row.
Item {
  id: root

  required property var theme
  required property var service
  property var entry: ({})      // { term }

  readonly property string kind: "browse"
  readonly property bool typing: false
  property var result: null
  property bool loading: false
  property string error: ""
  readonly property int found: result ? result.movies.length + result.series.length + result.episodes.length + result.collections.length + result.people.length : 0
  readonly property string statusText: loading ? "Searching…" : Format.count(found, "match", "matches")

  signal openItem(var item)
  signal playItem(var item, bool restart)
  signal menuItem(var item, Item anchor, real x, real y)
  signal openGrid(var entry)

  Component.onCompleted: reload()
  onEntryChanged: reload()

  function reload() {
    loading = true
    var term = entry.term || ""
    service.call("search", { term: term }, function(r, e) {
      if (!root || term !== (root.entry.term || "")) return
      root.loading = false
      root.error = e ? e.message : ""
      if (!e) root.result = r
    })
  }

  function patch(id, user) {
    if (!result) return
    var next = Object.assign({}, result)
    for (var k in next) next[k] = Items.patchUser(next[k], id, user)
    result = next
  }

  readonly property var rows: !result ? [] : [
    { key: "movies", title: "Films", items: result.movies, shape: "poster" },
    { key: "series", title: "Shows", items: result.series, shape: "poster" },
    { key: "episodes", title: "Episodes", items: result.episodes, shape: "landscape" },
    { key: "collections", title: "Collections", items: result.collections, shape: "poster" },
    { key: "people", title: "People", items: result.people, shape: "poster", cardWidth: theme.space(110) }
  ]

  function activate(item) {
    if (!item) return
    if (item.type === "Person") openGrid({ kind: "grid", title: item.name, personId: item.id, types: "Movie,Series", sort: "released", descending: true, recursive: true })
    else openItem(item)
  }

  function currentAnchor() {
    return page.currentCard()
  }

  function currentTarget() {
    var item = page.currentItem()
    return item && item.type !== "Person" ? item : null
  }

  function handleKey(id) {
    if (page.handleKey(id)) return
    if (id === "open") activate(page.currentItem())
  }

  PageHeader {
    id: header
    anchors { left: parent.left; right: parent.right; top: parent.top }
    theme: root.theme
    title: "“" + (root.entry.term || "") + "”"
    subtitle: root.loading ? "Searching…" : root.error || (root.found === 0 ? "Nothing matches. Try fewer words." : Format.count(root.found, "match", "matches"))
  }

  BrowsePage {
    id: page
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom }
    theme: root.theme
    service: root.service
    rows: root.rows
    topPadding: root.theme.space(4)
    onOpened: function(item) { root.activate(item) }
    onPlayed: function(item) { root.playItem(item, false) }
    onMenuRequested: function(item, anchor, x, y) { if (item.type !== "Person") root.menuItem(item, anchor, x, y) }
  }
}
