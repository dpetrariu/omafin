import QtQuick
import Quickshell
import Quickshell.Io
import "backend"
import "lib/Format.js" as Format

// Lives as long as the shell does. Owns the backend process, the settings,
// the account and the libraries, so the window opens onto data it already
// has. Playback state is reported by the backend, which keeps a session
// going while mpv plays even with the window shut.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Injected by the shell. Settings arrive later from the bar widget.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string executable: Quickshell.env("OMAFIN_BIN") || (pluginDir + "/bin/omafin")
  readonly property string version: manifest && manifest.version ? String(manifest.version) : "0.1.0"

  // ---------------------------------------------------------------- backend

  // The backend binary must match this plugin's version. A plugin installed
  // with `omarchy plugin add` or updated with `omarchy plugin update` has no
  // matching binary yet, so the release built for this version is downloaded
  // and checked. A development checkout (one with a target/ folder) builds its
  // own and is never overwritten.
  readonly property bool developmentBinary: !!Quickshell.env("OMAFIN_BIN")
  property string backendState: "checking"   // checking | downloading | ready | failed | outdated
  property string backendMessage: ""
  property string binaryVersion: ""
  property bool devCheckout: false
  readonly property bool binaryChecked: backendState !== "checking"
  readonly property bool binaryPresent: backendState === "ready"

  function checkBinary() {
    backendState = "checking"
    binaryVersion = ""
    // A Process whose program does not exist never reports an exit, so ask
    // whether the file is there before running it.
    existsProbe.running = true
  }

  function fetchBinary() {
    backendState = "downloading"
    backendMessage = ""
    fetcher.running = true
  }

  Process {
    id: checkoutProbe
    command: ["test", "-d", root.pluginDir + "/target"]
    onExited: function(code) {
      root.devCheckout = code === 0
      root.checkBinary()
    }
  }

  Process {
    id: existsProbe
    command: ["test", "-x", root.executable]
    onExited: function(code) {
      if (code === 0) {
        versionProbe.running = true
      } else if (root.developmentBinary) {
        root.backendState = "failed"
        root.backendMessage = "OMAFIN_BIN does not exist: " + root.executable
      } else if (root.devCheckout) {
        root.backendState = "failed"
        root.backendMessage = "Build the backend once: make install"
      } else {
        root.fetchBinary()
      }
    }
  }

  Process {
    id: versionProbe
    command: [root.executable, "version"]
    stdout: SplitParser {
      onRead: data => {
        var m = /^omafin (\S+) /.exec(String(data))
        if (m) root.binaryVersion = m[1]
      }
    }
    onExited: function(code) {
      if (root.developmentBinary) {
        root.backendState = code === 0 ? "ready" : "failed"
        root.backendMessage = code === 0 ? "" : "OMAFIN_BIN does not run: " + root.executable
        return
      }
      if (code === 0 && root.binaryVersion === root.version) {
        root.backendState = "ready"
        return
      }
      if (root.devCheckout) {
        // A developer's own build: say so, never replace it.
        root.backendState = code === 0 ? "outdated" : "failed"
        root.backendMessage = code === 0
          ? "This checkout's backend is " + root.binaryVersion + " but the plugin is " + root.version + "; run make install"
          : "Build the backend once: make install"
        return
      }
      root.fetchBinary()
    }
  }

  Process {
    id: fetcher
    command: [root.pluginDir + "/scripts/fetch-backend.sh", root.version]
    stderr: SplitParser {
      onRead: data => root.backendMessage = String(data)
    }
    onExited: function(code) {
      if (code === 0) {
        root.checkBinary()
        return
      }
      root.backendState = "failed"
      if (!root.backendMessage) root.backendMessage = "Downloading the backend failed (" + code + ")"
    }
  }

  readonly property alias backend: rustBackend
  Backend {
    id: rustBackend
    executable: root.backendState === "ready" || root.backendState === "outdated" ? root.executable : ""
    onNotification: function(method, params) {
      if (method === "server.changed") root.refreshServer()
      else if (method === "playback.changed") root.playbackChanged(params)
      else if (method === "downloads.changed") root.downloadChanged(params)
    }
  }
  readonly property bool ready: rustBackend.ready
  readonly property string mediaBase: rustBackend.info ? String(rustBackend.info.mediaBase) : ""
  readonly property bool mpvAvailable: !!rustBackend.info && rustBackend.info.mpv === true

  function call(method, params, callback) {
    rustBackend.call(method, params || {}, callback)
  }

  onReadyChanged: if (ready) {
    refreshServer()
    loadDownloads()
  }

  // ---------------------------------------------------------------- settings

  property var settings: ({})
  property bool signedIn: false
  property string tokenStorage: ""
  property bool settingsLoaded: false
  readonly property bool configured: signedIn && !!settings && (!!settings.serverUrl || !!settings.externalUrl)
  readonly property var uiPrefs: settings && settings.ui ? settings.ui : ({})
  readonly property var playbackPrefs: settings && settings.playback ? settings.playback : ({})

  function applySettingsResponse(result) {
    if (!result) return
    settings = result.settings || ({})
    signedIn = result.signedIn === true
    tokenStorage = String(result.tokenStorage || "")
    settingsLoaded = true
  }

  function loadSettings(callback) {
    call("settings.get", {}, function(result, error) {
      if (!error) root.applySettingsResponse(result)
      if (typeof callback === "function") callback(result, error)
    })
  }

  function updateSettings(patch, callback) {
    call("settings.update", { patch: patch }, function(result, error) {
      if (!error) root.applySettingsResponse(result)
      if (typeof callback === "function") callback(result, error)
    })
  }

  // Window preferences are saved a moment after the last change.
  property var pendingPrefs: ({})
  function setPref(key, value) {
    var next = Object.assign({}, pendingPrefs)
    next[key] = value
    pendingPrefs = next
    var merged = Object.assign({}, settings)
    merged.ui = Object.assign({}, uiPrefs)
    merged.ui[key] = value
    settings = merged
    prefTimer.restart()
  }
  function pref(key, fallback) {
    var value = uiPrefs[key]
    return value === undefined || value === null ? fallback : value
  }
  Timer {
    id: prefTimer
    interval: 600
    onTriggered: {
      var patch = root.pendingPrefs
      root.pendingPrefs = ({})
      root.call("settings.update", { patch: { ui: patch } }, function() {})
    }
  }

  // Bar widget settings travel through here, since the shell hands them to
  // the widget and not to the service.
  property var barSettings: ({})
  readonly property bool showBarIcon: barSettings.showBarIcon !== false
  function applySettings(values) {
    barSettings = values || ({})
  }

  // ---------------------------------------------------------------- server

  property var overview: null
  property string serverError: ""
  property bool serverLoading: false
  readonly property var user: overview ? overview.user : null
  readonly property var views: overview && overview.views ? overview.views : []
  readonly property string serverName: overview && overview.server ? String(overview.server.name || "") : String(settings.serverName || "")
  readonly property string serverVersion: overview && overview.server ? String(overview.server.version || "") : ""
  readonly property string route: overview && overview.route ? String(overview.route.route || "") : ""
  readonly property bool online: overview !== null && serverError === ""

  function refreshServer() {
    loadSettings(function() {
      if (!root.configured) {
        root.overview = null
        return
      }
      root.serverLoading = true
      root.call("server.overview", {}, function(result, error) {
        root.serverLoading = false
        if (error) {
          root.serverError = error.message
          return
        }
        root.serverError = ""
        root.overview = result
        root.libraryRevision++
      })
    })
  }

  // Bumped whenever watched marks, favourites or progress changed underneath
  // the views, so they reload what they show.
  property int libraryRevision: 0
  function libraryChanged() {
    libraryRevision++
  }

  // ---------------------------------------------------------------- playback

  // mpv plays outside the window; when it stops, the window's rows change.
  property var externalPlayback: null
  signal playbackFinished(var params)
  function playbackChanged(params) {
    if (!params) return
    if (params.state === "playing") {
      externalPlayback = params
    } else {
      externalPlayback = null
      libraryChanged()
      playbackFinished(params)
    }
  }

  // ---------------------------------------------------------------- downloads

  // Every download by item id, kept current by the backend's events.
  property var downloads: ({})
  property string downloadsRootFull: ""
  // The folder as people write it: ~ for the home folder.
  readonly property string downloadsRoot: {
    var home = String(Quickshell.env("HOME") || "")
    return home && downloadsRootFull.indexOf(home + "/") === 0 ? "~" + downloadsRootFull.slice(home.length) : downloadsRootFull
  }
  property real downloadsFree: 0
  readonly property var downloadList: Object.keys(downloads).map(function(k) { return downloads[k] })
  readonly property var activeDownload: downloadList.filter(function(d) { return d.state === "downloading" })[0] || null
  readonly property int downloadsWaiting: downloadList.filter(function(d) { return d.state === "queued" || d.state === "downloading" }).length
  readonly property int downloadsDone: downloadList.filter(function(d) { return d.state === "done" }).length

  function loadDownloads() {
    call("downloads.list", {}, function(result, error) {
      if (error) return
      var map = {}
      for (var i = 0; i < result.entries.length; i++) map[result.entries[i].id] = result.entries[i]
      root.downloads = map
      root.downloadsRootFull = String(result.root || "")
      root.downloadsFree = Number(result.free || 0)
    })
  }

  function downloadChanged(params) {
    if (!params) return
    var next = Object.assign({}, downloads)
    if (params.removed) delete next[params.removed]
    else if (params.entry && params.entry.id) {
      var before = downloads[params.entry.id]
      next[params.entry.id] = params.entry
      if (params.entry.state === "done" && before && before.state !== "done")
        notify("Downloaded " + Format.cardTitle(params.entry.card), "Ready to watch, even offline")
    }
    downloads = next
  }

  function notify(title, body) {
    Quickshell.execDetached(["notify-send", "--app-name=Omafin", "--icon=multimedia-video-player", "--", title, body])
  }

  function downloadOf(id) {
    return id && downloads[id] ? downloads[id] : null
  }

  // ---------------------------------------------------------------- media

  // An image the backend described as { id, tag }, at about this many
  // pixels wide. Jellyfin images are served by tag, so a new picture gets a
  // new address and the cache never shows a stale one.
  function imageUrl(image, kind, width) {
    if (!mediaBase || !image || !image.id || !image.tag) return ""
    return mediaBase + "/img/" + image.id + "/" + kind + "?tag=" + image.tag + "&w=" + Math.round(width || 400)
  }
  function mediaUrl(path) {
    return mediaBase && path ? mediaBase + path : ""
  }

  // ---------------------------------------------------------------- window

  property bool windowOpen: false
  function openWindow(payload) {
    if (shell && typeof shell.summon === "function") shell.summon("omafin", JSON.stringify(payload || {}))
  }

  // After the shell has handed over the manifest, which carries the version.
  Component.onCompleted: Qt.callLater(function() { checkoutProbe.running = true })
  Component.onDestruction: rustBackend.shutdown()
}
