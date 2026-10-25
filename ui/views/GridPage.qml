import QtQuick
import "../components"
import "../lib/Format.js" as Format
import "../lib/Items.js" as Items

// Every list of titles: a library, a collection, favourites, a genre, a
// person's films. One page, one set of controls, like Fladder's grid.
Item {
  id: root

  required property var theme
  required property var service
  property var entry: ({})   // { title, parentId, types, sort, descending, filters, genres, personId, recursive }
  property bool showBack: false

  readonly property string kind: "browse"
  readonly property bool typing: false
  property var items: []
  property int total: 0
  property bool loading: false
  property string error: ""
  property int generation: 0
  readonly property string prefKey: "grid:" + (entry.parentId || entry.personId || entry.key || entry.title || "")
  readonly property var saved: service.pref(prefKey, ({}))
  property string sort: saved.sort || entry.sort || "name"
  property bool descending: saved.descending !== undefined ? saved.descending === true : entry.descending === true
  property string show: saved.show || (entry.filters && entry.filters.length ? entry.filters[0] : "all")
  property var genres: entry.genres || []
  property var genreChoices: []
  readonly property string statusText: loading && items.length === 0 ? "Loading…" : Format.count(total, "title", "titles")

  signal openItem(var item)
  signal playItem(var item, bool restart)
  signal menuItem(var item, Item anchor, real x, real y)
  signal back()
  signal showMenu(var items, Item anchor, var handler)

  readonly property var sorts: [
    { id: "name", label: "Name" },
    { id: "added", label: "Date added" },
    { id: "released", label: "Release date" },
    { id: "rating", label: "Rating" },
    { id: "runtime", label: "Runtime" },
    { id: "played", label: "Last watched" },
    { id: "random", label: "Random" }
  ]
  readonly property var shows: [
    { id: "all", label: "Everything" },
    { id: "unplayed", label: "Not watched" },
    { id: "resumable", label: "In progress" },
    { id: "played", label: "Watched" },
    { id: "favorite", label: "Favourites" }
  ]
  function labelOf(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i].label
    return id
  }

  Component.onCompleted: {
    reload()
    // A library's own genres; a grid reached from a genre or a person
    // offers every genre on the server.
    service.call("genres.list", entry.parentId ? { parentId: entry.parentId } : {}, function(r, e) { if (!root) return; if (!e) root.genreChoices = r })
  }
  Connections {
    target: root.service
    function onLibraryRevisionChanged() { root.reload() }
  }

  function remember() {
    service.setPref(prefKey, { sort: sort, descending: descending, show: show })
  }

  function query(start) {
    var filters = (entry.filters || []).filter(function(f) { return f !== "played" && f !== "unplayed" && f !== "resumable" && f !== "favorite" })
    if (show !== "all") filters.push(show)
    if (entry.favorites) filters.push("favorite")
    var q = { start: start, limit: 120, sort: sort, descending: descending, filters: filters, genres: genres }
    if (entry.parentId) q.parentId = entry.parentId
    if (entry.personId) q.personId = entry.personId
    if (entry.types) q.types = entry.types
    if (entry.recursive !== undefined) q.recursive = entry.recursive
    return q
  }

  function reload() {
    generation++
    var mine = generation
    loading = true
    service.call("items.list", query(0), function(result, error) {
      if (!root || mine !== root.generation) return
      root.loading = false
      root.error = error ? error.message : ""
      if (error) return
      root.items = result.items
      root.total = result.total
      if (grid.currentIndex >= root.items.length) grid.currentIndex = 0
    })
  }

  function loadMore() {
    if (loading || items.length >= total) return
    var mine = generation
    loading = true
    service.call("items.list", query(items.length), function(result, error) {
      if (!root || mine !== root.generation) return
      root.loading = false
      if (error) { root.error = error.message; return }
      root.items = Items.appendUnique(root.items, result.items)
      root.total = result.total
    })
  }

  function patch(id, user) {
    items = Items.patchUser(items, id, user)
  }

  function currentAnchor() {
    return grid.currentCard()
  }

  function currentTarget() {
    return grid.currentItem
  }

  function handleKey(id) {
    if (grid.handleKey(id)) return
    if (id === "open" && grid.currentItem) openItem(grid.currentItem)
  }

  PageHeader {
    id: header
    anchors { left: parent.left; right: parent.right; top: parent.top }
    theme: root.theme
    title: root.entry.title || ""
    subtitle: root.loading && root.items.length === 0 ? "Loading…" : root.error !== "" ? root.error : Format.count(root.total, "title", "titles")
    showBack: root.showBack
    onBack: root.back()
  }

  Row {
    id: controls
    anchors { left: parent.left; leftMargin: root.theme.space(24); top: header.bottom }
    spacing: root.theme.space(8)
    height: root.theme.space(40)

    FilterChip {
      id: sortChip
      theme: root.theme
      icon: "sort"
      label: "Sort"
      value: root.labelOf(root.sorts, root.sort) + (root.sort === "random" ? "" : root.descending ? " ↓" : " ↑")
      clearable: root.sort !== "name" || root.descending
      anchors.verticalCenter: parent.verticalCenter
      onChoose: root.showMenu(root.sorts.map(function(s) {
        return { id: s.id, label: s.label, icon: s.id === root.sort ? "check" : "" }
      }).concat([{ id: "flip", label: root.descending ? "Ascending" : "Descending", icon: "sort" }]), sortChip, function(id) {
        if (id === "flip") root.descending = !root.descending
        else {
          // Newest, best and longest first; names A to Z.
          if (id !== root.sort) root.descending = id === "added" || id === "released" || id === "rating" || id === "played"
          root.sort = id
        }
        root.remember()
        root.reload()
      })
      onClear: { root.sort = "name"; root.descending = false; root.remember(); root.reload() }
    }
    FilterChip {
      id: showChip
      theme: root.theme
      icon: "filter"
      label: "Show"
      value: root.show === "all" ? "" : root.labelOf(root.shows, root.show)
      anchors.verticalCenter: parent.verticalCenter
      onChoose: root.showMenu(root.shows.map(function(s) {
        return { id: s.id, label: s.label, icon: s.id === root.show ? "check" : "" }
      }), showChip, function(id) { root.show = id; root.remember(); root.reload() })
      onClear: { root.show = "all"; root.remember(); root.reload() }
    }
    FilterChip {
      id: genreChip
      visible: root.genreChoices.length > 0 || root.genres.length > 0
      theme: root.theme
      icon: "tag"
      label: "Genre"
      value: root.genres.join(", ")
      anchors.verticalCenter: parent.verticalCenter
      onChoose: root.showMenu(root.genreChoices.map(function(g) {
        return { id: g, label: g, icon: root.genres.indexOf(g) >= 0 ? "check" : "" }
      }), genreChip, function(id) {
        var next = root.genres.slice()
        var at = next.indexOf(id)
        if (at >= 0) next.splice(at, 1); else next = [id]
        root.genres = next
        root.reload()
      })
      onClear: { root.genres = []; root.reload() }
    }
  }

  CardGrid {
    id: grid
    anchors { left: parent.left; right: parent.right; top: controls.bottom; bottom: parent.bottom }
    anchors.topMargin: root.theme.space(8)
    theme: root.theme
    service: root.service
    items: root.items
    total: root.total
    loading: root.loading && root.items.length > 0
    shape: root.entry.shape || "poster"
    cardWidth: root.theme.space(150) * (Number(root.service.pref("posterScale", 1)) || 1)
    onOpened: function(item) { root.openItem(item) }
    onPlayed: function(item) { root.playItem(item, false) }
    onMenuRequested: function(item, anchor, x, y) { root.menuItem(item, anchor, x, y) }
    onNeedMore: root.loadMore()
  }

  Text {
    anchors.centerIn: grid
    visible: !root.loading && root.items.length === 0
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(420))
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    text: root.error || (root.show !== "all" || root.genres.length > 0 ? "Nothing matches these filters." : "Nothing here yet.")
    textFormat: Text.PlainText
    color: root.error ? root.theme.urgent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.small
  }
}
