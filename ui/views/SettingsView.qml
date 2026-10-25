import QtQuick
import QtQuick.Controls as QQC
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// The server, the account, how videos play, the cache and what this is.
// Choices apply at once; address changes are tested before they are saved.
Item {
  id: root
  required property var theme
  required property var service

  readonly property bool isForm: true
  property var test: null
  property bool testing: false
  property string error: ""
  property var cache: null
  readonly property var p: service.playbackPrefs

  signal closed()
  signal toast(string text, string tone)

  Component.onCompleted: {
    lan.text = service.settings.serverUrl || ""
    wan.text = service.settings.externalUrl || ""
    audioLang.text = p.audioLanguage || ""
    subLang.text = p.subtitleLanguage || ""
    loadCache()
  }

  function loadCache() {
    service.call("cache.info", {}, function(r, e) { if (!root) return; if (!e) root.cache = r })
  }

  function setPlayback(key, value) {
    var patch = {}
    patch[key] = value
    service.updateSettings({ playback: patch }, function(r, e) { if (!root) return; if (e) root.toast(e.message, "error") })
  }

  function testConnection(then) {
    testing = true
    test = null
    error = ""
    service.call("auth.test", { serverUrl: lan.text, externalUrl: wan.text }, function(r, e) {
      if (!root) return
      root.testing = false
      if (e) { root.error = e.message; return }
      root.test = r
      if (typeof then === "function") then(r)
    })
  }

  function saveConnection() {
    testConnection(function(r) {
      var anyOk = (r.lan && r.lan.ok) || (r.wan && r.wan.ok)
      if (!anyOk) { root.error = "Neither address reached your Jellyfin server; nothing was saved"; return }
      root.service.updateSettings({ serverUrl: lan.text, externalUrl: wan.text, serverEnabled: lan.text.trim() !== "", externalEnabled: wan.text.trim() !== "" }, function(s, e) {
        if (!root) return
        if (e) { root.error = e.message; return }
        root.toast("Saved", "info")
        root.service.refreshServer()
      })
    })
  }

  function result(r) {
    if (!r) return ""
    return r.ok ? "Works — " + (r.name || "Jellyfin") + " " + (r.version || "") : r.error
  }

  // A row of choices where one is selected.
  component Choices: Row {
    id: choices
    property var options: []   // [{ id, label }]
    property var value
    signal picked(var id)
    spacing: root.theme.space(6)
    Repeater {
      model: choices.options
      delegate: TextButton {
        required property var modelData
        theme: root.theme
        text: modelData.label
        fontSize: root.theme.small
        selected: choices.value === modelData.id
        onClicked: choices.picked(modelData.id)
      }
    }
  }

  component Note: Text {
    color: root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    width: parent ? parent.width : 0
    wrapMode: Text.Wrap
  }

  WheelScroller { flickable: settingsFlick; notch: root.theme.space(200) }

  Flickable {
    id: settingsFlick
    anchors.fill: parent
    contentHeight: column.implicitHeight + root.theme.space(48)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: Math.max(root.theme.space(18), (parent.width - width) / 2)
      width: Math.min(parent.width - root.theme.space(36), root.theme.space(680))
      spacing: root.theme.space(12)

      PageHeader {
        width: parent.width
        theme: root.theme
        title: "Settings"
        subtitle: "Omafin " + (root.service.version || "") + (root.service.serverVersion ? "  ·  Jellyfin " + root.service.serverVersion : "")
        showBack: true
        onBack: root.closed()
      }

      SectionTitle { theme: root.theme; text: "Playback" }
      Note { text: "Where videos play. mpv handles every format, HDR and picture subtitles without the server converting anything; the window keeps you in Omafin. Either way, Jellyfin remembers where you stopped." }
      Choices {
        options: [{ id: "window", label: "In the window" }, { id: "mpv", label: "In mpv" }]
        value: root.p.player || "window"
        enabled: root.service.mpvAvailable || root.p.player === "mpv"
        onPicked: function(id) { root.setPlayback("player", id) }
      }
      Note { visible: !root.service.mpvAvailable; text: "mpv is not installed: sudo pacman -S mpv"; color: root.theme.urgent }

      SwitchRow {
        theme: root.theme
        text: "Let the server convert videos"
        detail: "Off: every video plays from its original file and the server never transcodes. Picture subtitles (PGS, DVD), which the window cannot draw, open in mpv. On: the server may convert to a lower quality, burn subtitles in, or fix a file the window cannot play."
        checked: root.p.allowTranscoding === true
        onToggled: root.setPlayback("allowTranscoding", !(root.p.allowTranscoding === true))
      }
      Note { visible: root.p.allowTranscoding === true; text: "Quality at home. Original sends files as they are; a limit makes the server convert larger ones." }
      Choices {
        visible: root.p.allowTranscoding === true
        options: [{ id: 0, label: "Original" }, { id: 40000000, label: "40 Mbps" }, { id: 20000000, label: "20 Mbps" }, { id: 10000000, label: "10 Mbps" }, { id: 4000000, label: "4 Mbps" }]
        value: Number(root.p.maxBitrate || 0)
        onPicked: function(id) { root.setPlayback("maxBitrate", id) }
      }
      Note { visible: root.p.allowTranscoding === true; text: "Quality away from home (when only the away address answers)." }
      Choices {
        visible: root.p.allowTranscoding === true
        options: [{ id: 0, label: "Original" }, { id: 20000000, label: "20 Mbps" }, { id: 8000000, label: "8 Mbps" }, { id: 4000000, label: "4 Mbps" }, { id: 1500000, label: "1.5 Mbps" }]
        value: Number(root.p.maxBitrateAway === undefined ? 8000000 : root.p.maxBitrateAway)
        onPicked: function(id) { root.setPlayback("maxBitrateAway", id) }
      }

      Note { text: "Intros and recaps, where the server knows them." }
      Choices {
        options: [{ id: "ask", label: "Offer a Skip button" }, { id: "auto", label: "Skip them" }, { id: "off", label: "Do nothing" }]
        value: root.p.skipIntro || "ask"
        onPicked: function(id) { root.setPlayback("skipIntro", id) }
      }
      Note { text: "Credits." }
      Choices {
        options: [{ id: "ask", label: "Offer a Skip button" }, { id: "auto", label: "Skip them" }, { id: "off", label: "Do nothing" }]
        value: root.p.skipCredits || "ask"
        onPicked: function(id) { root.setPlayback("skipCredits", id) }
      }
      SwitchRow {
        theme: root.theme
        text: "Play the next episode on its own"
        detail: "Up next counts down from the credits, or the last half minute, then starts the next episode."
        checked: root.p.autoplayNext !== false
        onToggled: root.setPlayback("autoplayNext", !(root.p.autoplayNext !== false))
      }

      Note { text: "Languages, as three-letter codes (eng, deu, fra). Empty follows each file." }
      Row {
        spacing: root.theme.space(10)
        width: parent.width
        Column {
          width: (parent.width - root.theme.space(10)) / 2
          spacing: root.theme.space(4)
          Note { text: "Audio" }
          TextField {
            id: audioLang
            width: parent.width
            placeholderText: "eng"
            font.family: root.theme.font
            font.pixelSize: root.theme.body
            onEditingFinished: if (text !== (root.p.audioLanguage || "")) root.setPlayback("audioLanguage", text)
          }
        }
        Column {
          width: (parent.width - root.theme.space(10)) / 2
          spacing: root.theme.space(4)
          Note { text: "Subtitles" }
          TextField {
            id: subLang
            width: parent.width
            placeholderText: "eng"
            font.family: root.theme.font
            font.pixelSize: root.theme.body
            onEditingFinished: if (text !== (root.p.subtitleLanguage || "")) root.setPlayback("subtitleLanguage", text)
          }
        }
      }
      Note { text: "When subtitles come on." }
      Choices {
        options: [{ id: "default", label: "As the file says" }, { id: "always", label: "Always" }, { id: "foreign", label: "For other languages" }, { id: "none", label: "Never" }]
        value: root.p.subtitleMode || "default"
        onPicked: function(id) { root.setPlayback("subtitleMode", id) }
      }
      Note { text: "Subtitle size in the window." }
      Choices {
        options: [{ id: 75, label: "Small" }, { id: 100, label: "Normal" }, { id: 130, label: "Large" }, { id: 170, label: "Huge" }]
        value: Number(root.p.subtitleSize || 100)
        onPicked: function(id) { root.setPlayback("subtitleSize", id) }
      }

      SectionTitle { theme: root.theme; text: "Server" }
      Note { text: "Omafin tries the home address first and the away address when home does not answer." }
      Note { text: "Home address (LAN)" }
      TextField { id: lan; width: parent.width; placeholderText: "http://192.168.1.10:8096"; font.family: root.theme.font; font.pixelSize: root.theme.body }
      Text { visible: !!root.test && !!root.test.lan; text: root.result(root.test ? root.test.lan : null); textFormat: Text.PlainText; color: root.test && root.test.lan && root.test.lan.ok ? root.theme.accent : root.theme.urgent; font.family: root.theme.font; font.pixelSize: root.theme.small }
      Note { text: "Away address (optional)" }
      TextField { id: wan; width: parent.width; placeholderText: "https://tv.example.com"; font.family: root.theme.font; font.pixelSize: root.theme.body }
      Text { visible: !!root.test && !!root.test.wan; text: root.result(root.test ? root.test.wan : null); textFormat: Text.PlainText; color: root.test && root.test.wan && root.test.wan.ok ? root.theme.accent : root.theme.urgent; font.family: root.theme.font; font.pixelSize: root.theme.small }
      Text {
        visible: root.error !== ""
        width: parent.width
        wrapMode: Text.Wrap
        text: root.error
        textFormat: Text.PlainText
        color: root.theme.urgent
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Row {
        spacing: root.theme.space(8)
        TextButton { theme: root.theme; text: "Test"; busy: root.testing; onClicked: root.testConnection() }
        TextButton { theme: root.theme; text: "Save"; primary: true; busy: root.testing; onClicked: root.saveConnection() }
      }

      SectionTitle { theme: root.theme; text: "Account" }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: (root.service.user ? root.service.user.name : root.service.settings.userName || "Not signed in")
          + (root.service.user && root.service.user.isAdmin ? "  ·  administrator" : "")
          + (root.service.serverName ? "  on  " + root.service.serverName : "")
          + (root.service.tokenStorage === "file" ? "\nThe session is in a private file, because no keyring answered." : "")
        textFormat: Text.PlainText
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      TextButton {
        theme: root.theme
        text: "Sign out"
        icon: "signOut"
        danger: true
        fontSize: root.theme.small
        onClicked: root.service.call("auth.signOut", {}, function(r, e) {
          if (!root) return
          if (e) { root.toast(e.message, "error"); return }
          root.service.applySettingsResponse(r)
          root.service.refreshServer()
          root.toast("Signed out. Your watch history stays on the server.", "info")
        })
      }

      SectionTitle { theme: root.theme; text: "Picture cache" }
      Note {
        text: root.cache ? Format.bytes(root.cache.bytes) + " of " + Format.bytes(root.cache.capMb * 1024 * 1024) + " used for posters and backdrops. The oldest go first when it is full." : "…"
      }
      Row {
        spacing: root.theme.space(6)
        Repeater {
          model: [250, 1000, 4000]
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: Format.bytes(modelData * 1024 * 1024)
            fontSize: root.theme.small
            selected: root.service.settings.cacheCapMb === modelData
            onClicked: root.service.updateSettings({ cacheCapMb: modelData }, function() { if (root) root.loadCache() })
          }
        }
        Item { width: root.theme.space(12); height: 1 }
        TextButton {
          theme: root.theme
          text: "Clear cache"
          fontSize: root.theme.small
          onClicked: root.service.call("cache.clear", {}, function(r) { if (!root) return; root.loadCache(); root.toast("Freed " + Format.bytes(r.freed), "info") })
        }
      }

      SectionTitle { theme: root.theme; text: "Keyboard" }
      Note {
        text: "Press ? in the window for every shortcut. To open Omafin from anywhere, add to ~/.config/hypr/bindings.lua:\n\no.bind(\"SUPER + SHIFT + J\", \"Omafin\", \"omarchy shell shell toggle omafin '{}'\")"
      }
    }
  }
}
