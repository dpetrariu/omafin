import QtQuick
import QtQuick.Controls as QQC
import QtMultimedia
import "../lib/Format.js" as Format

// The player. It asks the backend how to play an item, plays the stream the
// media proxy hands it, draws text subtitles itself, and reports where you
// are so Jellyfin's Continue watching follows you. Controls fade away while
// a video plays; every control has a key.
Item {
  id: root

  required property var theme
  required property var service
  property bool focusMode: false

  // What is playing: the backend's answer to play.prepare.
  property var info: null
  property var item: info ? info.item : null
  property bool preparing: false
  property string error: ""
  property var nextEpisode: null
  property bool started: false
  property real pendingStart: 0
  property bool sought: false
  property var cues: []
  property int subtitleIndex: -1
  property int audioIndex: -1
  property real maxBitrate: -1
  property var skipped: ({})
  property bool upNextDismissed: false
  property real upNextLeft: 0
  property bool showInfo: false
  property real seekAccumulated: 0
  // Every load and every close counts up; an answer for an older count is
  // dropped, so a close always wins over a load still on its way.
  property int generation: 0
  property string flash: ""

  readonly property bool active: info !== null || preparing || error !== ""
  readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
  readonly property real position: player.position / 1000
  readonly property real duration: info && info.runtime ? info.runtime : player.duration / 1000
  readonly property bool buffering: preparing || player.mediaStatus === MediaPlayer.LoadingMedia
    || player.mediaStatus === MediaPlayer.BufferingMedia || player.mediaStatus === MediaPlayer.StalledMedia
  readonly property var segment: info ? Format.segmentAt(info.segments, position) : null
  readonly property real upNextAt: info && nextEpisode ? Format.upNextAt(duration, info.segments) : -1
  readonly property bool upNextShown: upNextAt >= 0 && position >= upNextAt && !upNextDismissed && started
  readonly property var playback: service.playbackPrefs
  readonly property var subtitleStream: info ? info.subtitles.filter(function(s) { return s.index === root.subtitleIndex })[0] || null : null
  readonly property var audioStream: info ? info.audio.filter(function(s) { return s.index === root.audioIndex })[0] || null : null

  signal closed()
  signal toast(string text, string tone)
  signal openDetails(var item)
  signal menuRequested(var items, Item anchor, var handler)
  signal fullscreenToggled()

  // ---------------------------------------------------------------- loading

  // Start an item. `options`: { restart, start, audioIndex, subtitleIndex, maxBitrate, transcode }
  function play(target, options) {
    options = options || {}
    reportStop()
    var start = options.start !== undefined ? options.start
      : options.restart ? 0
      : target && target.user && !target.user.played && target.user.position ? target.user.position : 0
    load(target.id, start, options)
  }

  function load(id, start, options) {
    options = options || {}
    var mine = ++generation
    error = ""
    preparing = true
    started = false
    sought = false
    pendingStart = start
    cues = []
    player.stop()
    player.source = ""
    var params = { id: id, start: start }
    if (options.audioIndex !== undefined && options.audioIndex !== null) params.audioIndex = options.audioIndex
    if (options.subtitleIndex !== undefined && options.subtitleIndex !== null) params.subtitleIndex = options.subtitleIndex
    var bitrate = options.maxBitrate !== undefined ? options.maxBitrate : maxBitrate
    if (bitrate >= 0) params.maxBitrate = bitrate
    if (options.transcode) params.transcode = true
    service.call("play.prepare", params, function(result, err) {
      if (!root || mine !== root.generation) return
      root.preparing = false
      if (err) {
        root.error = err.message
        return
      }
      var sameItem = root.info && root.info.item && root.info.item.id === result.item.id
      root.info = result
      root.audioIndex = result.audioIndex === null ? -1 : result.audioIndex
      root.subtitleIndex = result.subtitleIndex === null ? -1 : result.subtitleIndex
      if (!sameItem) {
        root.skipped = ({})
        root.upNextDismissed = false
        root.nextEpisode = null
        root.loadNext()
      }
      root.loadSubtitles()
      player.source = root.service.mediaUrl(result.url)
      player.play()
    })
  }

  function loadNext() {
    var it = info ? info.item : null
    if (!it || it.type !== "Episode" || !it.seriesId) return
    var id = it.id
    service.call("show.nextEpisode", { id: it.id, seriesId: it.seriesId }, function(r, e) {
      if (!root || !root.info || root.info.item.id !== id) return
      root.nextEpisode = e ? null : r
    })
  }

  // Text subtitles come from the server as WebVTT and are drawn here;
  // picture subtitles are burned into the video by the server.
  function loadSubtitles() {
    cues = []
    var sub = subtitleStream
    if (!sub || !sub.url || (info && info.burnedIn)) return
    var request = new XMLHttpRequest()
    var wanted = sub.index
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE || !root) return
      if (root.subtitleIndex !== wanted) return
      if (request.status === 200) root.cues = Format.parseVtt(request.responseText)
      else root.toast("These subtitles did not load (" + request.status + ")", "error")
    }
    request.open("GET", service.mediaUrl(sub.url))
    request.send()
  }

  // ---------------------------------------------------------------- reporting

  function report(event) {
    if (!info || !info.session) return
    var params = { session: info.session, event: event, position: position, audioIndex: audioIndex, subtitleIndex: subtitleIndex }
    service.call("play.report", params, function() {})
  }

  // A session that never started may still have a transcode running on
  // the server; the backend ends it.
  function reportStop() {
    if (info && (started || info.hls)) report("stop")
    started = false
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.started && root.playing
    onTriggered: root.report("progress")
  }

  function close() {
    generation++
    reportStop()
    player.stop()
    player.source = ""
    info = null
    error = ""
    preparing = false
    showInfo = false
    cues = []
    nextEpisode = null
    service.libraryChanged()
    closed()
  }

  // ---------------------------------------------------------------- actions

  function togglePlay() {
    if (playing) player.pause()
    else player.play()
    poke()
  }

  function seekTo(seconds) {
    var target = Math.max(0, Math.min(duration > 0 ? duration - 1 : seconds, seconds))
    player.position = target * 1000
    if (started) report("seek")
    poke()
  }

  // Presses add up and land half a second after the last, as in Fladder.
  function seekBy(delta) {
    seekAccumulated += delta
    flash = (seekAccumulated > 0 ? "+" : "−") + Math.abs(seekAccumulated) + " s"
    seekTimer.restart()
    poke()
  }
  Timer {
    id: seekTimer
    interval: 500
    onTriggered: {
      root.seekTo(root.position + root.seekAccumulated)
      root.seekAccumulated = 0
      flashTimer.restart()
    }
  }
  Timer { id: flashTimer; interval: 900; onTriggered: root.flash = "" }
  function say(text) {
    flash = text
    flashTimer.restart()
  }

  function setVolume(v) {
    audio.volume = Math.max(0, Math.min(1, v))
    audio.muted = false
    say("Volume " + Math.round(audio.volume * 100) + " %")
    volumeSave.restart()
  }
  Timer {
    id: volumeSave
    interval: 1500
    onTriggered: root.service.updateSettings({ playback: { volume: Math.round(audio.volume * 100) } })
  }

  function setSpeed(rate) {
    var r = Math.round(Math.max(0.25, Math.min(3, rate)) * 100) / 100
    if (Math.abs(r - 1) < 0.06) r = 1
    player.playbackRate = r
    say("Speed " + r.toFixed(2) + "×")
  }

  function skipSegment() {
    var s = segment
    if (!s) return
    seekTo(s.end)
    say("Skipped the " + Format.segmentName(s.type))
  }

  function chapter(delta) {
    var list = info && info.chapters ? info.chapters : []
    if (list.length === 0) return
    var current = 0
    for (var i = 0; i < list.length; i++) if (list[i].start <= position + 1) current = i
    var next = delta > 0 ? current + 1 : (position - list[current].start > 3 ? current : current - 1)
    if (next < 0 || next >= list.length) return
    seekTo(list[next].start)
    say(list[next].name || "Chapter " + (next + 1))
  }

  function playNext() {
    if (!nextEpisode) return
    var next = nextEpisode
    play(next, { start: 0, audioIndex: undefined })
  }

  // Changing tracks: a direct file switches audio in place and subtitles
  // are drawn here; anything the server converts is asked for again.
  function chooseAudio(index) {
    if (index === audioIndex) return
    var ordinal = -1
    var embedded = info.audio.filter(function(s) { return !s.isExternal })
    for (var i = 0; i < embedded.length; i++) if (embedded[i].index === index) ordinal = i
    if (!info.hls && ordinal >= 0 && ordinal < player.audioTracks.length) {
      audioIndex = index
      player.activeAudioTrack = ordinal
      report("progress")
      return
    }
    reload({ audioIndex: index })
  }

  function chooseSubtitles(index) {
    var stream = info.subtitles.filter(function(s) { return s.index === index })[0] || null
    var needsServer = (stream && stream.picture) || (info.burnedIn && index !== subtitleIndex)
    if (needsServer) {
      if (stream && stream.picture) toast("The server draws these subtitles into the video; mpv shows them without converting (Shift+M)", "info")
      reload({ subtitleIndex: index })
      return
    }
    subtitleIndex = index
    loadSubtitles()
    if (started) report("progress")
  }

  function toggleSubtitles() {
    if (subtitleIndex >= 0) {
      lastSubtitle = subtitleIndex
      chooseSubtitles(-1)
      say("Subtitles off")
      return
    }
    var choice = lastSubtitle
    if (choice < 0 || !info.subtitles.some(function(s) { return s.index === choice })) {
      var text = info.subtitles.filter(function(s) { return !s.picture })
      if (text.length === 0 && info.subtitles.length === 0) { say("No subtitles"); return }
      choice = (text[0] || info.subtitles[0]).index
    }
    chooseSubtitles(choice)
    var s = info.subtitles.filter(function(x) { return x.index === choice })[0]
    say("Subtitles: " + Format.streamLabel(s))
  }
  property int lastSubtitle: -1

  function reload(change) {
    var options = { audioIndex: audioIndex, subtitleIndex: subtitleIndex }
    for (var k in change) options[k] = change[k]
    var at = position
    reportStop()
    load(info.item.id, at, options)
  }

  function continueInMpv() {
    if (!info) return
    var params = { id: info.item.id, start: position, audioIndex: audioIndex, subtitleIndex: subtitleIndex }
    reportStop()
    player.pause()
    var at = position
    var resume = { audioIndex: audioIndex, subtitleIndex: subtitleIndex }
    var id = info.item.id
    var mine = ++generation
    service.call("play.mpv", params, function(r, e) {
      if (!root || mine !== root.generation) return
      if (e) {
        // Carry on here, with a session of its own again.
        root.toast(e.message, "error")
        root.load(id, at, resume)
        return
      }
      root.toast("Playing in mpv", "info")
      root.close()
    })
  }

  // The pickers, as menus anchored to their buttons.
  function audioMenu(anchor) {
    if (!info) return
    menuRequested(info.audio.map(function(s) {
      return { id: String(s.index), label: Format.streamLabel(s), icon: s.index === root.audioIndex ? "check" : "" }
    }), anchor, function(id) { root.chooseAudio(Number(id)) })
  }
  function subtitleMenu(anchor) {
    if (!info) return
    menuRequested([{ id: "-1", label: "Off", icon: root.subtitleIndex < 0 ? "check" : "" }].concat(info.subtitles.map(function(s) {
      return { id: String(s.index), label: Format.streamLabel(s) + (s.picture ? " (converted by the server)" : ""), icon: s.index === root.subtitleIndex ? "check" : "" }
    })), anchor, function(id) { root.chooseSubtitles(Number(id)) })
  }
  readonly property var qualities: [
    { id: -1, label: "Automatic" }, { id: 0, label: "Original" },
    { id: 40000000, label: "40 Mbps" }, { id: 20000000, label: "20 Mbps" }, { id: 10000000, label: "10 Mbps" },
    { id: 6000000, label: "6 Mbps" }, { id: 3000000, label: "3 Mbps" }, { id: 1500000, label: "1.5 Mbps" }, { id: 720000, label: "720 kbps" }
  ]
  function qualityMenu(anchor) {
    menuRequested(qualities.map(function(q) {
      return { id: String(q.id), label: q.label + (q.id === -1 ? " (from Settings)" : ""), icon: q.id === root.maxBitrate ? "check" : "" }
    }), anchor, function(id) {
      root.maxBitrate = Number(id)
      // "Original" asks for no limit at all.
      root.reload({ maxBitrate: root.maxBitrate === 0 ? 400000000 : root.maxBitrate })
    })
  }
  function speedMenu(anchor) {
    menuRequested([0.5, 0.75, 1, 1.25, 1.5, 2].map(function(r) {
      return { id: String(r), label: r === 1 ? "Normal" : r + "×", icon: Math.abs(player.playbackRate - r) < 0.01 ? "check" : "" }
    }), anchor, function(id) { root.setSpeed(Number(id)) })
  }

  function handleKey(id) {
    if (!info) {
      if (id === "back" || id === "closePlayer") close()
      return
    }
    switch (id) {
    case "playPause": togglePlay(); return
    case "seekBack": seekBy(-10); return
    case "seekForward": seekBy(30); return
    case "seekBackSmall": seekTo(position - 5); return
    case "seekForwardSmall": seekTo(position + 5); return
    case "volumeUp": setVolume(audio.volume + 0.05); return
    case "volumeDown": setVolume(audio.volume - 0.05); return
    case "mute": audio.muted = !audio.muted; say(audio.muted ? "Muted" : "Sound on"); return
    case "speedUp": setSpeed(player.playbackRate + 0.1); return
    case "speedDown": setSpeed(player.playbackRate - 0.1); return
    case "skipSegment": if (upNextShown) playNext(); else skipSegment(); return
    case "subtitles": toggleSubtitles(); return
    case "subtitlePicker": subtitleMenu(subtitleButton); return
    case "audioPicker": audioMenu(audioButton); return
    case "nextChapter": chapter(1); return
    case "previousChapter": chapter(-1); return
    case "nextEpisode": if (nextEpisode) playNext(); else say("This is the last episode"); return
    case "fullscreenPlayer": fullscreenToggled(); return
    case "playbackInfo": showInfo = !showInfo; return
    case "continueInMpv": continueInMpv(); return
    case "back":
      if (upNextShown) { upNextDismissed = true; return }
      close()
      return
    case "closePlayer": close(); return
    }
  }

  // ---------------------------------------------------------------- media

  Rectangle {
    anchors.fill: parent
    color: "black"
  }

  VideoOutput {
    id: videoOut
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectFit
  }

  MediaPlayer {
    id: player
    videoOutput: videoOut
    audioOutput: AudioOutput {
      id: audio
      volume: Number(root.playback.volume === undefined ? 90 : root.playback.volume) / 100
    }
    // Subtitles are drawn by the window, never twice.
    activeSubtitleTrack: -1

    onPlaybackStateChanged: {
      if (!root.info) return
      if (playbackState === MediaPlayer.PlayingState) {
        if (!root.started) {
          root.started = true
          root.report("start")
        } else root.report("resume")
      } else if (playbackState === MediaPlayer.PausedState && root.started) {
        root.report("pause")
      }
    }
    onMediaStatusChanged: {
      if ((mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && !root.sought) {
        root.sought = true
        if (root.pendingStart > 1) player.position = root.pendingStart * 1000
        if (root.info && root.info.audioTrack && !root.info.hls && root.info.audioTrack - 1 < player.audioTracks.length) player.activeAudioTrack = root.info.audioTrack - 1
      }
      if (mediaStatus === MediaPlayer.EndOfMedia) root.ended()
    }
    onErrorOccurred: function(code, text) {
      if (!root.info) return
      root.error = text || "This video could not be played here"
    }
    onPositionChanged: root.checkSegments()
  }

  function ended() {
    if (nextEpisode && playback.autoplayNext !== false && !upNextDismissed) {
      playNext()
      return
    }
    close()
  }

  // Skip on its own when the setting says so, once per segment.
  function checkSegments() {
    var s = segment
    if (!s || !started) return
    var mode = s.type === "Outro" ? playback.skipCredits : s.type === "Intro" || s.type === "Recap" ? playback.skipIntro : "ask"
    var key = s.type + "@" + Math.round(s.start)
    if (mode === "auto" && !skipped[key] && !(s.type === "Outro" && upNextShown)) {
      var next = Object.assign({}, skipped)
      next[key] = true
      skipped = next
      seekTo(s.end)
      say("Skipped the " + Format.segmentName(s.type))
    }
  }

  // Up next counts down while it shows, then plays the next episode.
  onUpNextShownChanged: if (upNextShown) upNextLeft = Math.max(5, Math.min(30, duration - position))
  Timer {
    interval: 1000
    repeat: true
    running: root.upNextShown && root.playing && root.playback.autoplayNext !== false
    onTriggered: {
      root.upNextLeft -= 1
      if (root.upNextLeft <= 0) root.playNext()
    }
  }

  // ---------------------------------------------------------------- drawing

  // Subtitles, white with a dark outline, above the controls when they show.
  Text {
    id: subtitleText
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: chrome.shown ? bottomBar.height + root.theme.space(12) : parent.height * 0.06
    width: parent.width * 0.86
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.Wrap
    text: root.cues.length ? Format.cueAt(root.cues, root.position) : ""
    textFormat: Text.PlainText
    color: "white"
    style: Text.Outline
    styleColor: Qt.rgba(0, 0, 0, 0.9)
    font.family: root.theme.font
    font.pixelSize: Math.max(root.theme.body, root.height * 0.045) * Number(root.playback.subtitleSize || 100) / 100
    font.weight: Font.DemiBold
    Behavior on anchors.bottomMargin { NumberAnimation { duration: 200 } }
  }

  // Clicks on the picture pause; a double click is full screen.
  MouseArea {
    id: surface
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: chrome.shown ? Qt.ArrowCursor : Qt.BlankCursor
    acceptedButtons: Qt.LeftButton
    onPositionChanged: root.poke()
    onClicked: clickTimer.restart()
    onDoubleClicked: { clickTimer.stop(); root.fullscreenToggled() }
    onWheel: function(wheel) { root.setVolume(audio.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)) }
    Timer { id: clickTimer; interval: 220; onTriggered: root.togglePlay() }
  }

  // The controls show on movement and while paused, and fade otherwise.
  function poke() {
    chrome.shown = true
    hideTimer.restart()
  }
  Timer {
    id: hideTimer
    interval: 3000
    onTriggered: chrome.shown = !root.playing || scrub.pressed || scrubHover.hovered
  }
  onPlayingChanged: if (!playing) chrome.shown = true; else hideTimer.restart()

  Item {
    id: chrome
    anchors.fill: parent
    property bool shown: true
    opacity: shown || !root.info ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 250 } }

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: root.theme.space(110)
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.75) }
        GradientStop { position: 1; color: "transparent" }
      }
    }

    Row {
      anchors { left: parent.left; top: parent.top; margins: root.theme.space(16) }
      spacing: root.theme.space(12)
      IconButton {
        theme: root.theme
        icon: "back"
        color: "white"
        tooltip: "Stop and close (Esc)"
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.close()
      }
      Column {
        anchors.verticalCenter: parent.verticalCenter
        Text {
          text: root.item ? Format.cardTitle(root.item) : ""
          textFormat: Text.PlainText
          color: "white"
          font.family: root.theme.font
          font.pixelSize: root.theme.heading
          font.bold: true
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (root.item) { root.openDetails(root.item); root.close() } }
        }
        Text {
          visible: !!root.item && root.item.type === "Episode"
          text: root.item ? Format.episodeCode(root.item) + "  " + (root.item.name || "") : ""
          textFormat: Text.PlainText
          color: Qt.rgba(1, 1, 1, 0.8)
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
      }
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: bottomBar.height + root.theme.space(80)
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.85) }
      }
    }

    Column {
      id: bottomBar
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      anchors.leftMargin: root.theme.space(24)
      anchors.rightMargin: root.theme.space(24)
      anchors.bottomMargin: root.theme.space(14)
      spacing: root.theme.space(4)

      // Time, chapters, segments and the scrubbing preview.
      Item {
        id: scrubArea
        width: parent.width
        height: root.theme.space(26)

        readonly property real fraction: root.duration > 0 ? Math.min(1, root.position / root.duration) : 0
        readonly property real hoverSeconds: root.duration > 0 ? Math.max(0, Math.min(1, scrubHover.point.position.x / width)) * root.duration : 0

        Rectangle {
          id: track
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: scrubHover.hovered || scrub.pressed ? root.theme.space(7) : root.theme.space(4)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.25)
          Behavior on height { NumberAnimation { duration: 120 } }
          Repeater {
            model: root.info ? root.info.segments : []
            delegate: Rectangle {
              required property var modelData
              x: root.duration > 0 ? modelData.start / root.duration * track.width : 0
              width: root.duration > 0 ? Math.max(2, (modelData.end - modelData.start) / root.duration * track.width) : 0
              height: track.height
              color: Qt.rgba(1, 1, 1, 0.35)
            }
          }
          Rectangle {
            width: (scrub.pressed ? scrub.fraction : scrubArea.fraction) * parent.width
            height: parent.height
            radius: parent.radius
            color: root.theme.accent
          }
          Repeater {
            model: root.info && root.duration > 0 ? root.info.chapters.filter(function(c) { return c.start > 1 }) : []
            delegate: Rectangle {
              required property var modelData
              x: modelData.start / root.duration * track.width
              width: root.theme.space(2)
              height: track.height
              color: Qt.rgba(0, 0, 0, 0.6)
            }
          }
        }
        Rectangle {
          x: (scrub.pressed ? scrub.fraction : scrubArea.fraction) * parent.width - width / 2
          anchors.verticalCenter: parent.verticalCenter
          width: root.theme.space(scrubHover.hovered || scrub.pressed ? 14 : 0)
          height: width
          radius: width / 2
          color: root.theme.accent
        }

        HoverHandler { id: scrubHover }
        MouseArea {
          id: scrub
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          property real fraction: 0
          onPressed: function(m) { fraction = Math.max(0, Math.min(1, m.x / width)) }
          onPositionChanged: function(m) { if (pressed) fraction = Math.max(0, Math.min(1, m.x / width)) }
          onReleased: root.seekTo(fraction * root.duration)
        }

        // A frame from trickplay, or the time and chapter, over the cursor.
        Rectangle {
          id: preview
          visible: (scrubHover.hovered || scrub.pressed) && root.duration > 0
          readonly property real at: scrub.pressed ? scrub.fraction * root.duration : scrubArea.hoverSeconds
          readonly property var trick: root.info ? root.info.trickplay : null
          readonly property var frame: trick ? Format.trickplayFrame(trick, at) : null
          readonly property real thumbWidth: trick ? root.theme.space(240) : 0
          readonly property real thumbHeight: trick && trick.width ? thumbWidth * trick.height / trick.width : 0
          width: Math.max(thumbWidth, previewText.implicitWidth + root.theme.space(16))
          height: thumbHeight + previewText.implicitHeight + root.theme.space(10)
          x: Math.max(0, Math.min(parent.width - width, (scrub.pressed ? scrub.fraction * parent.width : scrubHover.point.position.x) - width / 2))
          y: -height - root.theme.space(8)
          radius: root.theme.radius
          color: Qt.rgba(0, 0, 0, 0.85)
          border.width: root.theme.borderWidth
          border.color: Qt.rgba(1, 1, 1, 0.25)
          clip: true
          Item {
            visible: !!preview.frame
            width: preview.thumbWidth
            height: preview.thumbHeight
            clip: true
            Image {
              readonly property real scale: preview.trick && preview.trick.width ? preview.thumbWidth / preview.trick.width : 1
              x: preview.frame ? -preview.frame.x * scale : 0
              y: preview.frame ? -preview.frame.y * scale : 0
              width: preview.trick ? preview.trick.width * preview.trick.tileWidth * scale : 0
              height: preview.trick ? preview.trick.height * preview.trick.tileHeight * scale : 0
              source: preview.frame && root.info ? root.service.mediaUrl("/jf/Videos/" + root.info.item.id + "/Trickplay/" + preview.trick.width + "/" + preview.frame.tile + ".jpg?mediaSourceId=" + root.info.sourceId) : ""
              asynchronous: true
              cache: true
            }
          }
          Text {
            id: previewText
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.theme.space(5)
            anchors.horizontalCenter: parent.horizontalCenter
            text: {
              var name = ""
              var list = root.info ? root.info.chapters : []
              for (var i = 0; i < list.length; i++) if (list[i].start <= preview.at) name = list[i].name || ""
              return Format.clock(preview.at) + (name && !/^Chapter \d+$/.test(name) ? "  ·  " + name : "")
            }
            textFormat: Text.PlainText
            color: "white"
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
        }
      }

      Item {
        width: parent.width
        height: root.theme.space(22)
        Text {
          anchors.left: parent.left
          text: Format.clock(root.position) + "  /  " + Format.clock(root.duration)
          color: "white"
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        Text {
          anchors.right: parent.right
          text: Format.endsAt(root.duration - root.position, Date.now(), player.playbackRate) + "  ·  " + Format.methodLabel(root.info ? root.info.method : "")
          textFormat: Text.PlainText
          color: Qt.rgba(1, 1, 1, 0.75)
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showInfo = !root.showInfo }
        }
      }

      Item {
        width: parent.width
        height: root.theme.space(48)

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.theme.space(4)
          IconButton {
            id: audioButton
            theme: root.theme
            icon: "audio"
            color: "white"
            enabled: !!root.info && root.info.audio.length > 1
            tooltip: "Audio: " + (root.audioStream ? Format.streamLabel(root.audioStream) : "default") + " (a)"
            onClicked: root.audioMenu(audioButton)
          }
          IconButton {
            id: subtitleButton
            theme: root.theme
            icon: "subtitles"
            color: root.subtitleIndex >= 0 ? root.theme.accent : "white"
            selected: root.subtitleIndex >= 0
            enabled: !!root.info && root.info.subtitles.length > 0
            tooltip: "Subtitles: " + (root.subtitleStream ? Format.streamLabel(root.subtitleStream) : "off") + " (t; Shift+T to choose)"
            onClicked: root.subtitleMenu(subtitleButton)
          }
          IconButton {
            id: qualityButton
            theme: root.theme
            icon: "quality"
            color: "white"
            tooltip: "Quality..."
            onClicked: root.qualityMenu(qualityButton)
          }
          IconButton {
            id: speedButton
            theme: root.theme
            icon: "speed"
            color: player.playbackRate !== 1 ? root.theme.accent : "white"
            tooltip: "Speed: " + player.playbackRate.toFixed(2) + "× (Ctrl+Up / Ctrl+Down)"
            onClicked: root.speedMenu(speedButton)
          }
        }

        Row {
          anchors.centerIn: parent
          spacing: root.theme.space(10)
          IconButton {
            theme: root.theme
            icon: "previous"
            color: "white"
            enabled: !!root.info && root.info.chapters.length > 0
            tooltip: "Previous chapter (PgUp)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.chapter(-1)
          }
          IconButton {
            theme: root.theme
            icon: "rewind"
            color: "white"
            iconSize: root.theme.heading
            tooltip: "Back 10 seconds (←)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.seekBy(-10)
          }
          IconButton {
            theme: root.theme
            icon: root.playing ? "pause" : "play"
            color: "white"
            size: root.theme.space(48)
            iconSize: root.theme.display
            tooltip: (root.playing ? "Pause" : "Play") + " (Space)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.togglePlay()
          }
          IconButton {
            theme: root.theme
            icon: "forward10"
            color: "white"
            iconSize: root.theme.heading
            tooltip: "Forward 30 seconds (→)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.seekBy(30)
          }
          IconButton {
            theme: root.theme
            icon: "next"
            color: "white"
            enabled: root.nextEpisode !== null
            tooltip: root.nextEpisode ? "Next: " + Format.episodeCode(root.nextEpisode) + " " + (root.nextEpisode.name || "") + " (Shift+N)" : "No next episode"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.playNext()
          }
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.theme.space(4)
          IconButton {
            theme: root.theme
            icon: audio.muted || audio.volume === 0 ? "mute" : audio.volume < 0.5 ? "volumeLow" : "volume"
            color: "white"
            tooltip: (audio.muted ? "Unmute" : "Mute") + " (m)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: audio.muted = !audio.muted
          }
          QQC.Slider {
            width: root.theme.space(100)
            anchors.verticalCenter: parent.verticalCenter
            from: 0
            to: 1
            value: audio.muted ? 0 : audio.volume
            onMoved: root.setVolume(value)
          }
          IconButton {
            visible: root.service.mpvAvailable
            theme: root.theme
            icon: "external"
            color: "white"
            tooltip: "Continue in mpv (Shift+M)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.continueInMpv()
          }
          IconButton {
            theme: root.theme
            icon: root.focusMode ? "fullscreenExit" : "fullscreen"
            color: "white"
            tooltip: "Full window (f)"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.fullscreenToggled()
          }
        }
      }
    }
  }

  // Skip the intro, recap or credits: bold at first, then quieter, as in
  // Fladder, so it never nags.
  Rectangle {
    id: skipButton
    readonly property real into: root.segment ? root.position - root.segment.start : 0
    readonly property string mode: !root.segment ? "off" : root.segment.type === "Outro" ? String(root.playback.skipCredits || "ask") : String(root.playback.skipIntro || "ask")
    visible: !!root.segment && mode !== "off" && !root.upNextShown && root.started
    opacity: chrome.shown || into < Math.min(60, (root.segment ? root.segment.end - root.segment.start : 0) * 0.2) ? 1 : 0.35
    anchors.right: parent.right
    anchors.rightMargin: root.theme.space(32)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: bottomBar.height + root.theme.space(48)
    width: skipRow.implicitWidth + root.theme.space(28)
    height: root.theme.space(42)
    radius: height / 2
    color: skipMouse.containsMouse ? root.theme.accent : Qt.rgba(1, 1, 1, 0.92)
    Behavior on opacity { NumberAnimation { duration: 300 } }
    Row {
      id: skipRow
      anchors.centerIn: parent
      spacing: root.theme.space(8)
      Text {
        text: "Skip " + (root.segment ? Format.segmentName(root.segment.type) : "")
        color: "black"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
      Rectangle {
        width: keyHint.implicitWidth + root.theme.space(8)
        height: keyHint.implicitHeight + root.theme.space(2)
        radius: root.theme.radius
        color: Qt.rgba(0, 0, 0, 0.12)
        anchors.verticalCenter: parent.verticalCenter
        Text { id: keyHint; anchors.centerIn: parent; text: "s"; color: "black"; font.family: root.theme.font; font.pixelSize: root.theme.caption }
      }
    }
    MouseArea { id: skipMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.skipSegment() }
  }

  // Up next: the next episode, with a countdown when autoplay is on.
  Rectangle {
    visible: root.upNextShown && !!root.nextEpisode
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: root.theme.space(28)
    anchors.bottomMargin: bottomBar.height + root.theme.space(40)
    width: Math.min(parent.width - root.theme.space(56), root.theme.space(440))
    height: upNextColumn.implicitHeight + root.theme.space(28)
    radius: root.theme.radius * 2
    color: root.theme.alpha(root.theme.popupBackground, 0.94)
    border.width: root.theme.borderWidth
    border.color: root.theme.popupBorder

    Column {
      id: upNextColumn
      anchors.fill: parent
      anchors.margins: root.theme.space(14)
      spacing: root.theme.space(10)
      Text {
        text: root.playback.autoplayNext !== false && root.playing ? "UP NEXT IN " + Math.max(0, Math.round(root.upNextLeft)) : "UP NEXT"
        color: root.theme.accent
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
        font.bold: true
        font.letterSpacing: 1.5
      }
      Row {
        spacing: root.theme.space(12)
        width: parent.width
        MediaCard {
          theme: root.theme
          service: root.service
          item: root.nextEpisode
          shape: "landscape"
          showText: false
          width: root.theme.space(160)
          onClicked: root.playNext()
          onPlayClicked: root.playNext()
        }
        Column {
          width: parent.width - root.theme.space(172)
          spacing: root.theme.space(4)
          Text {
            width: parent.width
            text: root.nextEpisode ? Format.episodeCode(root.nextEpisode) : ""
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
          Text {
            width: parent.width
            text: root.nextEpisode ? root.nextEpisode.name || "" : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.body
            font.bold: true
          }
          Text {
            width: parent.width
            text: root.nextEpisode ? Format.runtime(root.nextEpisode.runtime) : ""
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
      }
      Row {
        spacing: root.theme.space(8)
        TextButton {
          theme: root.theme
          text: "Play now"
          icon: "play"
          primary: true
          onClicked: root.playNext()
        }
        TextButton {
          theme: root.theme
          text: "Keep watching"
          onClicked: root.upNextDismissed = true
        }
      }
    }
  }

  // How it plays, for the curious (i).
  Rectangle {
    visible: root.showInfo && !!root.info
    anchors { top: parent.top; right: parent.right; margins: root.theme.space(20) }
    width: infoColumn.implicitWidth + root.theme.space(28)
    height: infoColumn.implicitHeight + root.theme.space(24)
    radius: root.theme.radius
    color: Qt.rgba(0, 0, 0, 0.8)
    Column {
      id: infoColumn
      anchors.centerIn: parent
      spacing: root.theme.space(4)
      Repeater {
        model: !root.info ? [] : [
          Format.methodLabel(root.info.method) + (root.info.transcodeReasons.length ? " because of " + Format.reasonsLabel(root.info.transcodeReasons) : ""),
          "Video: " + (Format.videoTag(root.info.video) || "unknown"),
          "Audio: " + (root.audioStream ? Format.streamLabel(root.audioStream) : "default"),
          "Subtitles: " + (root.subtitleStream ? Format.streamLabel(root.subtitleStream) + (root.info.burnedIn ? " (burned in)" : "") : "off"),
          "Player: " + (player.mediaStatus === MediaPlayer.BufferingMedia ? "buffering" : root.playing ? "playing" : "paused") + "  ·  " + player.playbackRate.toFixed(2) + "×"
        ]
        delegate: Text {
          required property var modelData
          text: modelData
          textFormat: Text.PlainText
          color: "white"
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
      }
    }
  }

  // Seeks and volume, said briefly in the middle.
  Rectangle {
    visible: root.flash !== ""
    anchors.centerIn: parent
    width: flashText.implicitWidth + root.theme.space(32)
    height: flashText.implicitHeight + root.theme.space(18)
    radius: height / 2
    color: Qt.rgba(0, 0, 0, 0.7)
    Text {
      id: flashText
      anchors.centerIn: parent
      text: root.flash
      textFormat: Text.PlainText
      color: "white"
      font.family: root.theme.font
      font.pixelSize: root.theme.heading
    }
  }

  // Waiting on the server or the network.
  Glyph {
    visible: root.buffering && root.error === "" && root.flash === ""
    anchors.centerIn: parent
    name: "refresh"
    size: root.theme.display * 1.5
    color: "white"
    font.family: root.theme.font
    RotationAnimation on rotation { running: root.buffering; from: 0; to: 360; duration: 1100; loops: Animation.Infinite }
  }

  // A file the window cannot play: offer the ways that can.
  Column {
    visible: root.error !== ""
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(520))
    spacing: root.theme.space(12)
    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: "warning"
      size: root.theme.display * 1.5
      color: root.theme.urgent
      font.family: root.theme.font
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.error
      textFormat: Text.PlainText
      color: "white"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
    }
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: root.theme.space(8)
      TextButton {
        visible: !!root.info && !root.info.hls
        theme: root.theme
        text: "Let the server convert it"
        primary: true
        onClicked: root.reload({ transcode: true })
      }
      TextButton {
        visible: !!root.info && root.service.mpvAvailable
        theme: root.theme
        text: "Play in mpv"
        icon: "external"
        onClicked: root.continueInMpv()
      }
      TextButton {
        theme: root.theme
        text: "Close"
        onClicked: root.close()
      }
    }
  }
}
