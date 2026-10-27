import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "components"
import "views"
import "keys/Keymap.js" as Keymap
import "lib/Format.js" as Format

// The window. It owns where you are (section, pages, the player), which key
// context is live, and what every action does: play, mark watched,
// favourite, open. Views draw what they are given and report what was
// asked for.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "dpetrariu.omafin"
  readonly property bool ready: !!service && service.ready
  readonly property bool configured: !!service && service.configured

  Theme { id: appTheme }

  // ---------------------------------------------------------------- host contract

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (e) {}
    closingFromHost = false
    opened = true
    if (service) service.windowOpen = true
    if (payload.section) go(String(payload.section))
    Qt.callLater(focusContent)
  }

  function close() {
    playRequest++
    closingFromHost = true
    opened = false
    if (service) service.windowOpen = false
    // A video does not keep playing behind a closed window.
    if (player.active) player.close()
    closingFromHost = false
  }

  // `omarchy-shell shell call dpetrariu.omafin navigate <id>` — keyboard actions that
  // only move around, for scripts and keybindings. Anything that changes
  // the library or starts playback is refused here.
  readonly property var navigationIds: ["left", "right", "up", "down", "pageDown", "pageUp", "first", "last",
    "open", "back", "help", "sidebar", "search", "refresh", "fullscreen", "settings", "historyBack", "historyForward"]
  function navigate(id) {
    var name = String(id || "")
    if (name.indexOf("go:") === 0) {
      go(name.slice(3))
      return "ok"
    }
    if (name.indexOf("search:") === 0) {
      searchBar.text = name.slice(7)
      runSearch(name.slice(7))
      return "ok"
    }
    if (navigationIds.indexOf(name) < 0) return "refused"
    runShortcut(name, "")
    return "ok"
  }

  // `omarchy-shell shell call dpetrariu.omafin screenshot /path.png` saves what the
  // window shows, for bug reports and the UI tests.
  function screenshot(path) {
    var target = String(path || "")
    if (target.indexOf("/") !== 0 || !/\.png$/.test(target)) return "refused"
    frame.grabToImage(function(result) { result.saveToFile(target) })
    return "ok"
  }

  // Handles for the off-screen UI tests.
  readonly property var testHooks: ({ confirm: confirmDialog, menu: menu, player: player, toast: toast, status: statusBar,
    content: contentLoader, setup: setupLoader, settings: settingsLoader, window: window })

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  onOpenedChanged: Qt.callLater(function() { window.visible = root.opened })

  // ---------------------------------------------------------------- navigation

  // Home, each of your libraries, then favourites. Libraries come from the
  // server in the order you set there.
  readonly property var sections: {
    var out = [{ id: "home", label: "Home", icon: "home", group: "home" }]
    var views = service ? service.views : []
    for (var i = 0; i < views.length; i++) {
      var v = views[i]
      out.push({ id: "view:" + v.id, label: v.name, icon: Format.viewIcon(v.collectionType), group: "libraries",
        count: v.childCount ? Format.thousands(v.childCount) : "", view: v })
    }
    out.push({ id: "favorites", label: "Favourites", icon: "favorite", group: "mine" })
    if (service && service.downloadList.length > 0)
      out.push({ id: "downloaded", label: "Downloaded", icon: "downloaded", group: "mine", count: service.downloadsDone > 0 ? String(service.downloadsDone) : "" })
    return out
  }

  property string section: "home"
  // Pages opened inside a section: a title, a grid, a search.
  property var stack: []
  readonly property var page: stack.length > 0 ? stack[stack.length - 1] : null
  property bool settingsOpen: false
  property bool sidebarCollapsed: service ? service.pref("sidebarCollapsed", false) === true : false
  property bool helpOpen: false
  property bool fullscreen: false
  // A phone-width window: tabs at the bottom instead of the sidebar.
  readonly property bool narrow: narrowOverride || window.width < appTheme.space(640)
  // Off-screen tests cannot resize the window, so they ask for the layout.
  property bool narrowOverride: false

  readonly property bool needsSetup: ready && service.settingsLoaded && !configured
  readonly property bool playerShown: player.active

  function viewFor(id) {
    var s = sections.filter(function(x) { return x.id === id })[0]
    return s && s.view ? s.view : null
  }

  // The grid a library opens to: shows in a TV library, films in a film one.
  function sectionEntry(id) {
    if (id === "favorites") return { kind: "grid", key: "favorites", title: "Favourites", favorites: true, types: "Movie,Series,Episode", recursive: true, sort: "name" }
    if (id === "downloaded") return { kind: "grid", key: "downloaded", title: "Downloaded", downloaded: true, sort: "added", descending: true }
    var v = viewFor(id)
    if (!v) return null
    var types = Format.viewTypes(v.collectionType)
    return { kind: "grid", key: v.id, title: v.name, parentId: v.id, types: types, recursive: types !== "" && types !== "BoxSet", sort: "name",
      collectionType: v.collectionType, shape: v.collectionType === "homevideos" ? "landscape" : "poster" }
  }

  function go(id) {
    if (id === "settings") {
      settingsOpen = true
      remember()
      return
    }
    if (id !== "home" && id !== "favorites" && id !== "downloaded" && !viewFor(id)) {
      // A library by name, for `navigate go:Movies`.
      var byName = sections.filter(function(s) { return s.label.toLowerCase() === String(id).toLowerCase() })[0]
      if (!byName) return
      id = byName.id
    }
    settingsOpen = false
    stack = []
    searchBar.clear()
    section = id
    remember()
    Qt.callLater(focusContent)
  }

  function push(entry) {
    settingsOpen = false
    var next = stack.slice()
    next.push(entry)
    stack = next
    remember()
    Qt.callLater(focusContent)
  }

  function pop() {
    var next = stack.slice()
    next.pop()
    stack = next
    remember()
    Qt.callLater(focusContent)
  }

  // Back and Forward through the places visited, like a browser. Escape
  // still leaves the innermost thing first; these walk the history.
  property var history: [{ section: "home", stack: [], settingsOpen: false }]
  property int historyIndex: 0
  property bool restoring: false
  readonly property bool canGoBackInHistory: historyIndex > 0
  readonly property bool canGoForward: historyIndex < history.length - 1

  function snapshot() {
    return { section: section, stack: JSON.parse(JSON.stringify(stack)), settingsOpen: settingsOpen }
  }

  function remember() {
    if (restoring) return
    var current = snapshot()
    var last = history[historyIndex]
    if (last && JSON.stringify(last) === JSON.stringify(current)) return
    var next = history.slice(0, historyIndex + 1)
    next.push(current)
    if (next.length > 100) next.shift()
    history = next
    historyIndex = next.length - 1
  }

  function restoreHistory(entry) {
    restoring = true
    searchBar.clear()
    section = entry.section
    stack = JSON.parse(JSON.stringify(entry.stack))
    settingsOpen = entry.settingsOpen
    restoring = false
    Qt.callLater(focusContent)
  }

  function historyBack() {
    if (!canGoBackInHistory) return
    historyIndex--
    restoreHistory(history[historyIndex])
  }

  function historyForward() {
    if (!canGoForward) return
    historyIndex++
    restoreHistory(history[historyIndex])
  }

  function setSettings(on) {
    if (settingsOpen === on) return
    settingsOpen = on
    remember()
  }

  // Escape: leave the innermost thing first.
  function goBack() {
    playRequest++
    if (menu.visible) { menu.close(); return }
    if (anyDialogOpen()) { closeDialogs(); return }
    if (helpOpen) { helpOpen = false; return }
    if (player.active) { player.handleKey("back"); return }
    if (searchBar.focused) { searchBar.clear(); focusContent(); return }
    if (settingsOpen) { setSettings(false); focusContent(); return }
    if (stack.length > 0) { pop(); return }
    if (section !== "home") { go("home"); return }
    requestClose()
  }

  function focusContent() {
    keyPark.forceActiveFocus()
  }

  // ---------------------------------------------------------------- key context

  readonly property string keyContext: Keymap.contextFor({
    dialog: anyDialogOpen() || helpOpen,
    page: (settingsOpen || needsSetup || (contentLoader.item && contentLoader.item.isForm === true)) && !player.active,
    searchFocused: searchBar.focused || (contentLoader.item && contentLoader.item.typing === true),
    player: player.active
  })

  function anyDialogOpen() {
    return confirmDialog.opened
  }

  function closeDialogs() {
    confirmDialog.close()
    focusContent()
  }

  function view() {
    return contentLoader.item
  }

  function runShortcut(id, sequence) {
    switch (id) {
    case "back": goBack(); return
    case "backAlt": if (stack.length > 0) pop(); else if (section !== "home") go("home"); return
    case "settings": setSettings(!settingsOpen); return
    case "historyBack": historyBack(); return
    case "historyForward": historyForward(); return
    case "help": helpOpen = !helpOpen; return
    case "fullscreen": fullscreen = !fullscreen; return
    case "sidebar": toggleSidebar(); return
    case "search": searchBar.focusField(); return
    case "section":
      var n = Number(sequence.slice(-1))
      var index = n === 0 ? 9 : n - 1
      if (index < sections.length) go(sections[index].id)
      return
    }
    if (player.active) {
      player.handleKey(id)
      return
    }
    var item = view()
    if (!item) return
    var target = typeof item.currentTarget === "function" ? item.currentTarget() : null
    switch (id) {
    case "refresh": refreshContent(); return
    case "play": if (target) playItem(target, { restart: false }); return
    case "restart": if (target) playItem(target, { restart: true }); return
    case "playMpv": if (target) playInMpv(target, {}); return
    case "watched": if (target) toggleWatched(target); return
    case "favorite": if (target) toggleFavorite(target); return
    case "download":
      if (target && Format.isPlayable(target)) {
        var at = typeof item.currentAnchor === "function" ? item.currentAnchor() : null
        downloadAction(target, at || contentLoader)
      }
      return
    case "menu":
      if (!target) return
      var anchor = typeof item.currentAnchor === "function" ? item.currentAnchor() : null
      if (anchor) showItemMenu(target, anchor, anchor.width / 2, anchor.height / 2)
      else showItemMenu(target, contentLoader, contentLoader.width / 2, contentLoader.height / 3)
      return
    }
    if (typeof item.handleKey === "function") item.handleKey(id)
  }

  function refreshContent() {
    service.refreshServer()
  }

  function toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed
    service.setPref("sidebarCollapsed", sidebarCollapsed)
  }

  // ---------------------------------------------------------------- actions

  // Open a card: titles get their page, collections and folders a grid,
  // seasons their show with that season chosen, people their films.
  function openItem(item) {
    if (!item) return
    switch (item.type) {
    case "Season":
      if (item.seriesId) push({ kind: "details", item: { id: item.seriesId, type: "Series", name: item.seriesName }, seasonId: item.id })
      return
    case "Person":
      push({ kind: "grid", title: item.name, personId: item.id, types: "Movie,Series", sort: "released", descending: true, recursive: true })
      return
    case "CollectionFolder":
    case "UserView":
      go("view:" + item.id)
      return
    }
    if (Format.opensGrid(item)) {
      push({ kind: "grid", title: item.name, parentId: item.id, sort: item.type === "BoxSet" ? "released" : "name" })
      return
    }
    push({ kind: "details", item: item })
  }

  function openSeries(id) {
    if (id) push({ kind: "details", item: { id: id, type: "Series" } })
  }

  // Something to play: a film or episode as it is; a show plays the episode
  // that comes next for you; a collection opens instead.
  function resolvePlayable(item, then) {
    if (Format.isPlayable(item)) { then(item); return }
    if (item.type === "Series" || item.type === "Season") {
      var seriesId = item.type === "Series" ? item.id : item.seriesId
      service.call("item.get", { id: seriesId }, function(r, e) {
        if (e) { toast.show(e.message, { tone: "error" }); return }
        if (r.nextUp && (item.type === "Series" || r.nextUp.seasonId === item.id)) { then(r.nextUp); return }
        root.service.call("show.episodes", { id: seriesId, seasonId: item.type === "Season" ? item.id : "" }, function(eps, e2) {
          if (e2 || !eps || eps.length === 0) { toast.show(e2 ? e2.message : "This show has no episodes yet", { tone: "error" }); return }
          var unwatched = eps.filter(function(x) { return !x.user || !x.user.played })
          then(unwatched[0] || eps[0])
        })
      })
      return
    }
    openItem(item)
  }

  // Counts each play asked for; a show's next episode arrives later, and is
  // dropped if something newer was asked for, or the window was closed.
  property int playRequest: 0

  function playItem(item, options) {
    if (!item) return
    options = options || {}
    var mine = ++playRequest
    resolvePlayable(item, function(target) {
      if (mine !== root.playRequest || !root.opened) return
      if (String(root.service.playbackPrefs.player) === "mpv" && root.service.mpvAvailable) {
        root.playInMpv(target, options)
        return
      }
      player.play(target, options)
      root.focusContent()
    })
  }

  function playInMpv(item, options) {
    if (!service.mpvAvailable) {
      toast.show("mpv is not installed (sudo pacman -S mpv)", { tone: "error" })
      return
    }
    resolvePlayable(item, function(target) {
      var params = { id: target.id }
      var o = options || {}
      params.start = o.restart ? 0 : target.user && !target.user.played && target.user.position ? target.user.position : 0
      if (o.audioIndex !== undefined && o.audioIndex !== null) params.audioIndex = o.audioIndex
      if (o.subtitleIndex !== undefined && o.subtitleIndex !== null) params.subtitleIndex = o.subtitleIndex
      if (o.pip === true) params.pip = true
      toast.show(o.pip === true ? "Popping out " + Format.cardTitle(target) + "…" : "Opening " + Format.cardTitle(target) + " in mpv…")
      root.service.call("play.mpv", params, function(r, e) {
        if (e) toast.show(e.message, { tone: "error" })
      })
    })
  }

  function patchViews(id, user) {
    var item = view()
    if (item && typeof item.patch === "function") item.patch(id, user)
  }

  // Watched and favourite apply at once and can be undone from the toast.
  function toggleWatched(item, quiet, restorePosition) {
    var played = !(item.user && item.user.played)
    var before = item.user ? Object.assign({}, item.user) : {}
    patchViews(item.id, { played: played, position: played ? null : (restorePosition || null), percent: null })
    var params = { id: item.id, played: played }
    if (!played && restorePosition) params.restorePosition = restorePosition
    service.call("item.setPlayed", params, function(r, e) {
      if (e) {
        root.patchViews(item.id, before)
        toast.show(e.message, { tone: "error" })
        return
      }
      root.patchViews(item.id, r)
      if (quiet) {
        if (restorePosition) root.service.libraryChanged()
        return
      }
      var name = Format.cardTitle(item) + (item.type === "Episode" ? " " + Format.episodeCode(item) : "")
      toast.show((played ? "Marked " + name + " as watched" : "Marked " + name + " as not watched"), {
        actionText: "Undo",
        action: function() { root.toggleWatched(Object.assign({}, item, { user: r }), true, played ? before.position : 0) }
      })
      // Rows elsewhere (Continue watching, Next up) change too.
      if (item.type === "Series" || item.type === "Season") root.service.libraryChanged()
    })
  }

  function toggleFavorite(item) {
    var favorite = !(item.user && item.user.favorite)
    patchViews(item.id, { favorite: favorite })
    service.call("item.setFavorite", { id: item.id, favorite: favorite }, function(r, e) {
      if (e) {
        root.patchViews(item.id, { favorite: !favorite })
        toast.show(e.message, { tone: "error" })
        return
      }
      root.patchViews(item.id, r)
      toast.show(favorite ? "Added " + Format.cardTitle(item) + " to favourites" : "Removed " + Format.cardTitle(item) + " from favourites", {
        actionText: "Undo",
        action: function() { root.toggleFavorite(Object.assign({}, item, { user: r })) }
      })
    })
  }

  function clearResume(item) {
    service.call("item.clearResume", { id: item.id }, function(r, e) {
      if (e) { toast.show(e.message, { tone: "error" }); return }
      root.service.libraryChanged()
      toast.show("Removed " + Format.cardTitle(item) + " from Continue watching")
    })
  }

  // ---------------------------------------------------------------- downloads

  function startDownload(item) {
    service.call("downloads.add", { id: item.id }, function(r, e) {
      if (e) { toast.show(e.message, { tone: "error" }); return }
      if (r.state === "done") toast.show(Format.cardTitle(item) + " is already downloaded")
      else toast.show("Downloading " + Format.cardTitle(item) + (item.type === "Episode" ? " " + Format.episodeCode(item) : "") + " to " + root.service.downloadsRoot)
    })
  }

  function downloadSeason(seriesId, season, count) {
    service.call("downloads.addSeason", { seriesId: seriesId, seasonId: season.id }, function(r, e) {
      if (e) { toast.show(e.message, { tone: "error" }); return }
      toast.show(r.added > 0 ? "Downloading " + Format.count(r.added, "episode", "episodes") + " of " + season.name
        : "Every episode of " + season.name + " is downloaded or on its way")
    })
  }

  function downloadCall(method, item, done) {
    service.call(method, { id: item.id }, function(r, e) {
      if (e) toast.show(e.message, { tone: "error" })
      else if (typeof done === "function") done(r)
    })
  }

  // What the download button does, by where the download is.
  function downloadAction(item, anchor) {
    var e = service.downloadOf(item.id)
    if (!e) { startDownload(item); return }
    switch (e.state) {
    case "done":
      confirmDeleteDownload(item, e)
      return
    case "downloading":
    case "queued":
      showMenu([{ id: "pause", label: "Pause download", icon: "pause" },
                { id: "cancel", label: "Cancel download", icon: "close", danger: true }], anchor, function(id) {
        root.downloadCall(id === "pause" ? "downloads.pause" : "downloads.cancel", item)
      })
      return
    case "paused":
    case "failed":
      showMenu([{ id: "resume", label: e.state === "failed" ? "Try again" : "Resume download", icon: "download" },
                { id: "cancel", label: "Cancel download", icon: "close", danger: true }], anchor, function(id) {
        root.downloadCall(id === "resume" ? "downloads.resume" : "downloads.cancel", item)
      })
      return
    case "missing":
      showMenu([{ id: "again", label: "Download again", icon: "download" },
                { id: "forget", label: "Remove from downloads", icon: "trash" }], anchor, function(id) {
        if (id === "again") root.startDownload(item)
        else root.downloadCall("downloads.remove", item)
      })
      return
    }
  }

  function confirmDeleteDownload(item, entry) {
    var name = Format.cardTitle(item) + (item.type === "Episode" ? " " + Format.episodeCode(item) : "")
    confirmDialog.ask({
      title: "Delete download?",
      message: "Move " + name + " (" + Format.bytes(entry.size) + ") to the trash? It stays on your Jellyfin server, and you can put the file back from the trash in Files.",
      confirmText: "Move to trash",
      onConfirm: function() {
        root.downloadCall("downloads.remove", item, function() { toast.show("Moved " + name + " to the trash") })
      }
    })
  }

  // The same actions on every card, wherever it is: right click, the "."
  // key, or the ⋯ button on a page.
  function showItemMenu(item, anchor, x, y) {
    if (!item) return
    var items = []
    var playable = Format.isPlayable(item) || item.type === "Series" || item.type === "Season"
    var progress = Format.progress(item) > 0
    if (playable) {
      items.push({ id: "play", label: Format.playLabel(item), icon: "play", shortcut: "p" })
      if (progress) items.push({ id: "restart", label: "Play from the start", icon: "restart", shortcut: "P" })
      if (service.mpvAvailable) items.push({ id: "mpv", label: "Play in mpv", icon: "external", shortcut: "m" })
      if (service.mpvAvailable) items.push({ id: "pip", label: "Play popped out", icon: "pip" })
    }
    if (!page || page.kind !== "details" || page.item.id !== item.id) items.push({ id: "open", label: "Open", icon: "info", shortcut: "enter" })
    if (item.type === "Episode" && item.seriesId) items.push({ id: "series", label: "Go to " + (item.seriesName || "the show"), icon: "shows" })
    var played = item.user && item.user.played
    items.push({ id: "watched", label: played ? "Mark as not watched" : "Mark as watched", icon: played ? "played" : "playedOn", shortcut: "w" })
    var fav = item.user && item.user.favorite
    items.push({ id: "favorite", label: fav ? "Remove from favourites" : "Add to favourites", icon: fav ? "favorite" : "favoriteOn", shortcut: "f" })
    if (progress) items.push({ id: "clearResume", label: "Remove from Continue watching", icon: "close" })
    if (Format.isPlayable(item)) {
      var dl = service.downloadOf(item.id)
      var state = dl ? dl.state : "none"
      items.push({ id: "download", icon: state === "done" ? "trash" : state === "paused" ? "pause" : "download", shortcut: "D",
        label: state === "done" ? "Delete download..." : state === "downloading" || state === "queued" ? "Pause or cancel the download..."
          : state === "paused" || state === "failed" ? "Resume or cancel the download..." : state === "missing" ? "Download again..." : "Download",
        danger: state === "done" })
    }
    // A show's page offers its chosen season.
    var details = page && page.kind === "details" ? view() : null
    if (details && details.currentSeason && (item.type === "Series" || item.type === "Episode") && details.seriesId) {
      var season = details.currentSeason
      items.push({ id: "downloadSeason", label: "Download " + season.name + (details.episodes.length ? " (" + Format.count(details.episodes.length, "episode", "episodes") + ")" : ""), icon: "download" })
    }
    showMenu(items, anchor, function(id) {
      switch (id) {
      case "play": root.playItem(item, { restart: false }); break
      case "restart": root.playItem(item, { restart: true }); break
      case "mpv": root.playInMpv(item, {}); break
      case "pip": root.playInMpv(item, { pip: true }); break
      case "open": root.openItem(item); break
      case "series": root.openSeries(item.seriesId); break
      case "watched": root.toggleWatched(item); break
      case "favorite": root.toggleFavorite(item); break
      case "clearResume": root.clearResume(item); break
      case "download": root.downloadAction(item, anchor); break
      case "downloadSeason": root.downloadSeason(details.seriesId, details.currentSeason, details.episodes.length); break
      }
    }, x, y)
  }

  property var menuHandler: function() {}
  function showMenu(items, item, handler, x, y) {
    menu.items = items
    root.menuHandler = handler
    if (x !== undefined && y !== undefined) menu.openAt(item, x, y)
    else menu.openBelow(item)
  }

  function runSearch(text) {
    var term = String(text || "").trim()
    if (term === "") return
    if (page && page.kind === "search") {
      var next = stack.slice()
      next[next.length - 1] = { kind: "search", term: term }
      stack = next
      remember()
    } else {
      push({ kind: "search", term: term })
    }
    focusContent()
  }

  // mpv finished: say so, and offer the next episode of a show.
  Connections {
    target: root.service
    function onPlaybackFinished(params) {
      if (params && params.ended) toast.show("Finished in mpv")
    }
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: "Omafin"
    color: appTheme.background
    implicitWidth: appTheme.space(1280)
    implicitHeight: appTheme.space(820)
    minimumSize: Qt.size(appTheme.space(360), appTheme.space(420))
    visible: false

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    // Everything in the window, as one item: it can be grabbed as an image.
    Item {
      id: frame
      anchors.fill: parent

    Item {
      id: keyPark
      focus: true
      anchors.fill: parent
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Alt) sidebar.showNumbers = true
      }
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Alt) sidebar.showNumbers = false
      }
      onActiveFocusChanged: if (!activeFocus) sidebar.showNumbers = false
    }

    KeyRouter {
      context: root.keyContext
      onTriggered: function(id, sequence) { root.runShortcut(id, sequence) }
    }

    // Mouse back button steps back the way Escape does.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.BackButton | Qt.ForwardButton
      z: -1
      onClicked: function(mouse) {
        if (mouse.button === Qt.ForwardButton) root.historyForward()
        else root.goBack()
      }
    }

    // ------------------------------------------------------------ header
    Item {
      id: header
      visible: !root.fullscreen && !(root.playerShown && root.fullscreen)
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: visible ? appTheme.space(52) : 0

      Row {
        id: identity
        anchors.left: parent.left
        anchors.leftMargin: appTheme.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: appTheme.space(10)
        Mark {
          size: appTheme.heading + 4
          color: appTheme.accent
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          visible: !root.narrow
          text: "Omafin"
          color: appTheme.foreground
          font.family: appTheme.font
          font.pixelSize: appTheme.heading
          anchors.verticalCenter: parent.verticalCenter
        }
        Row {
          visible: root.configured
          anchors.verticalCenter: parent.verticalCenter
          IconButton {
            theme: appTheme
            icon: "back"
            enabled: root.canGoBackInHistory
            tooltip: "Back (Alt+Left)"
            onClicked: root.historyBack()
          }
          IconButton {
            theme: appTheme
            icon: "forward"
            enabled: root.canGoForward
            tooltip: "Forward (Alt+Right)"
            onClicked: root.historyForward()
          }
        }
      }

      SearchBar {
        id: searchBar
        theme: appTheme
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(appTheme.space(560), parent.width - identity.width - actions.width - appTheme.space(80))
        visible: root.configured
        onSubmitted: function(text) { root.runSearch(text) }
        onCancelled: { clear(); root.focusContent() }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: appTheme.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: appTheme.space(4)
        visible: root.configured
        IconButton {
          theme: appTheme
          icon: "refresh"
          tooltip: "Reload (r)"
          busy: root.service ? root.service.serverLoading : false
          onClicked: root.refreshContent()
        }
        IconButton {
          theme: appTheme
          icon: "settings"
          tooltip: "Settings (Ctrl+,)"
          selected: root.settingsOpen
          onClicked: root.setSettings(!root.settingsOpen)
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: appTheme.borderWidth
        color: appTheme.border
      }
    }

    // ------------------------------------------------------------ body
    Item {
      id: body
      anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: bottomNav.top }

      readonly property bool compact: width < appTheme.space(820)

      Sidebar {
        id: sidebar
        theme: appTheme
        visible: root.configured && !root.fullscreen && !root.narrow
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: visible ? implicitWidth : 0
        sections: root.sections
        current: root.settingsOpen ? "" : root.section
        collapsed: root.sidebarCollapsed || body.compact
        footerTitle: root.service && root.service.user ? String(root.service.user.name || "") : (root.service ? String(root.service.settings.userName || "Jellyfin") : "Jellyfin")
        footerDetail: !root.service ? "" : root.service.serverError !== "" ? root.service.serverError
          : (root.service.serverName ? root.service.serverName + (root.service.route === "wan" ? " · away" : "") : "Connecting…")
        footerAttention: !!root.service && root.service.serverError !== ""
        footerIcon: !!root.service && root.service.serverError !== "" ? "cloudOff" : "server"
        onPicked: function(id) { root.go(id) }
        onFooterClicked: root.setSettings(true)
      }

      Item {
        id: content
        anchors { left: sidebar.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        clip: true

        Loader {
          id: contentLoader
          anchors.fill: parent
          active: root.configured && !root.settingsOpen
          // A new entry builds a new view, so a page never shows the last one's data.
          readonly property var entry: root.page ? root.page : (root.section === "home" ? { kind: "home" } : root.sectionEntry(root.section))
          readonly property string entryKey: JSON.stringify(entry)
          sourceComponent: {
            var e = entry
            if (!e) return homeView
            if (e.kind === "details") return detailsPage
            if (e.kind === "grid") return gridPage
            if (e.kind === "search") return searchPage
            return homeView
          }
          onEntryKeyChanged: {
            // Same component, new entry: rebuild it.
            if (status === Loader.Ready) { active = false; active = Qt.binding(function() { return root.configured && !root.settingsOpen }) }
          }
        }

        Loader {
          id: settingsLoader
          anchors.fill: parent
          active: root.settingsOpen && root.configured
          sourceComponent: SettingsView {
            theme: appTheme
            service: root.service
            onClosed: { root.setSettings(false); root.focusContent() }
            onToast: function(text, tone) { toast.show(text, { tone: tone }) }
          }
        }

        Loader {
          id: setupLoader
          anchors.fill: parent
          active: root.ready && root.service.settingsLoaded && !root.configured
          sourceComponent: SetupView {
            theme: appTheme
            service: root.service
          }
        }

        BackendStatus {
          anchors.fill: parent
          visible: !!root.service && !root.service.ready
          theme: appTheme
          service: root.service
        }
      }
    }

    // The player covers the body, or the whole window in focus mode.
    Player {
      id: player
      theme: appTheme
      service: root.service
      visible: active
      focusMode: root.fullscreen
      anchors.fill: root.fullscreen ? parent : body
      z: 50
      onClosed: root.focusContent()
      onToast: function(text, tone) { toast.show(text, { tone: tone }) }
      onToastAction: function(text, actionText, action) { toast.show(text, { actionText: actionText, action: action, duration: 8000 }) }
      onOpenDetails: function(item) { root.openItem(item) }
      onMenuRequested: function(items, anchor, handler) { root.showMenu(items, anchor, handler) }
      onFullscreenToggled: root.fullscreen = !root.fullscreen
    }

    // ------------------------------------------------------------ bottom tabs
    BottomNav {
      id: bottomNav
      theme: appTheme
      anchors { left: parent.left; right: parent.right; bottom: statusBar.top }
      visible: root.narrow && root.configured && !root.fullscreen
      height: visible ? implicitHeight : 0
      sections: root.sections
      current: root.settingsOpen ? "" : root.section
      onPicked: function(id) { root.go(id) }
      onMoreRequested: function(item, rest) {
        root.showMenu(rest.map(function(s) { return { id: s.id, label: s.label, icon: s.icon } }), item, function(id) { root.go(id) })
      }
    }

    // ------------------------------------------------------------ status bar
    StatusBar {
      id: statusBar
      theme: appTheme
      visible: !root.fullscreen
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: visible ? implicitHeight : 0
      context: root.keyContext
      sidebarCollapsed: root.sidebarCollapsed
      leftIcon: !root.service ? "" : root.service.activeDownload ? "download" : root.service.externalPlayback ? "external" : root.service.serverError ? "cloudOff" : "server"
      leftAttention: !!root.service && root.service.serverError !== ""
      leftText: {
        var s = root.service
        if (!s) return ""
        var d = s.activeDownload
        if (d) return "Downloading " + Format.cardTitle(d.card) + (d.card.type === "Episode" ? " " + Format.episodeCode(d.card) : "")
          + " · " + Format.downloadLine(d) + (s.downloadsWaiting > 1 ? " · " + (s.downloadsWaiting - 1) + " waiting" : "")
        if (s.externalPlayback) return "Playing in mpv"
        return s.serverError ? "Offline" : s.serverName
      }
      middleText: {
        if (player.active && player.item) return Format.cardTitle(player.item) + (player.item.type === "Episode" ? " " + Format.episodeCode(player.item) : "")
        return contentLoader.item && contentLoader.item.statusText ? contentLoader.item.statusText : ""
      }
      onSidebarToggled: root.toggleSidebar()
      onLeftClicked: root.setSettings(true)
    }

    // ------------------------------------------------------------ overlays
    Toast {
      id: toast
      theme: appTheme
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: statusBar.height + appTheme.space(18)
    }

    ShortcutHelp {
      theme: appTheme
      anchors.fill: parent
      visible: root.helpOpen
      z: 300
      onClosed: root.helpOpen = false
    }

    PopupMenu {
      id: menu
      theme: appTheme
      parent: frame
      onActivated: function(id) { root.menuHandler(id) }
      onClosed: root.focusContent()
    }

    ConfirmDialog { id: confirmDialog; theme: appTheme; onDismissed: root.focusContent() }
    }
  }

  // ---------------------------------------------------------------- views

  Component {
    id: homeView
    HomeView {
      theme: appTheme
      service: root.service
      onOpenItem: function(item) { root.openItem(item) }
      onPlayItem: function(item, restart) { root.playItem(item, { restart: restart }) }
      onMenuItem: function(item, anchor, x, y) { root.showItemMenu(item, anchor, x, y) }
      onOpenGrid: function(entry) { root.push(entry) }
    }
  }

  Component {
    id: detailsPage
    DetailsPage {
      theme: appTheme
      service: root.service
      entry: contentLoader.entry
      onOpenItem: function(item) { root.openItem(item) }
      onPlayItem: function(item, restart) { root.playItem(item, { restart: restart }) }
      onPlayWith: function(item, options) { root.playItem(item, options) }
      onMenuItem: function(item, anchor, x, y) { root.showItemMenu(item, anchor, x, y) }
      onOpenGrid: function(entry) { root.push(entry) }
      onOpenSeries: function(id) { root.openSeries(id) }
      onToggleWatched: function(item) { root.toggleWatched(item) }
      onToggleFavorite: function(item) { root.toggleFavorite(item) }
      onPlayInMpv: function(item, options) { root.playInMpv(item, options) }
      onShowMenu: function(items, anchor, handler) { root.showMenu(items, anchor, handler) }
      onDownloadClicked: function(item, anchor) { root.downloadAction(item, anchor) }
    }
  }

  Component {
    id: gridPage
    GridPage {
      theme: appTheme
      service: root.service
      entry: contentLoader.entry
      showBack: root.stack.length > 0
      onOpenItem: function(item) { root.openItem(item) }
      onPlayItem: function(item, restart) { root.playItem(item, { restart: restart }) }
      onMenuItem: function(item, anchor, x, y) { root.showItemMenu(item, anchor, x, y) }
      onBack: root.pop()
      onShowMenu: function(items, anchor, handler) { root.showMenu(items, anchor, handler) }
    }
  }

  Component {
    id: searchPage
    SearchPage {
      theme: appTheme
      service: root.service
      entry: contentLoader.entry
      onOpenItem: function(item) { root.openItem(item) }
      onPlayItem: function(item, restart) { root.playItem(item, { restart: restart }) }
      onMenuItem: function(item, anchor, x, y) { root.showItemMenu(item, anchor, x, y) }
      onOpenGrid: function(entry) { root.push(entry) }
    }
  }
}
