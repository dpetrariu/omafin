import QtQuick
import "../components"
import "../lib/Format.js" as Format
import "../lib/Items.js" as Items

// A film, a show or an episode: the backdrop with its logo, one row of
// actions, the story, then episodes, seasons, cast and similar titles as
// rows. A show's Play button plays the episode that comes next for you.
Item {
  id: root

  required property var theme
  required property var service
  property var entry: ({})          // { kind: "details", item, seasonId }

  readonly property string kind: "browse"
  readonly property bool typing: false
  property var item: entry.item || null
  property var details: null
  property bool loading: false
  property string error: ""
  property var seasons: []
  property var episodes: []
  property string seasonId: entry.seasonId || ""
  property var similar: []
  property bool overviewOpen: false
  // Picks for this play, before it starts. -1 means subtitles off.
  property var audioIndex: null
  property var subtitleIndex: null

  readonly property var shown: details || item
  readonly property bool isSeries: !!shown && shown.type === "Series"
  readonly property bool isEpisode: !!shown && shown.type === "Episode"
  readonly property string seriesId: !shown ? "" : isSeries ? shown.id : (shown.seriesId || "")
  readonly property var source: details && details.sources && details.sources.length > 0 ? details.sources[0] : null
  readonly property var streams: source ? source.streams : []
  readonly property var audioStreams: streams.filter(function(s) { return s.type === "Audio" })
  readonly property var subtitleStreams: streams.filter(function(s) { return s.type === "Subtitle" })
  readonly property var videoStream: streams.filter(function(s) { return s.type === "Video" })[0] || null
  readonly property var playTarget: {
    if (!shown) return null
    if (isSeries) return details && details.nextUp ? details.nextUp : (episodes.length > 0 ? episodes[0] : null)
    return Format.isPlayable(shown) ? shown : null
  }
  readonly property string statusText: !shown ? "" : isSeries ? Format.count(seasons.length, "season", "seasons") + (episodes.length ? "  ·  " + Format.count(episodes.length, "episode", "episodes") + " in this season" : "")
    : source ? [Format.videoTag(videoStream), source.size ? Format.bytes(source.size) : "", source.container ? String(source.container).toUpperCase() : ""].filter(function(s) { return s !== "" }).join("  ·  ") : ""

  signal openItem(var item)
  signal playItem(var item, bool restart)
  signal playWith(var item, var options)
  signal menuItem(var item, Item anchor, real x, real y)
  signal openGrid(var entry)
  signal openSeries(string id)
  signal toggleWatched(var item)
  signal toggleFavorite(var item)
  signal playInMpv(var item, var options)
  signal showMenu(var items, Item anchor, var handler)
  signal downloadClicked(var item, Item anchor)

  Component.onCompleted: reload()
  Connections {
    target: root.service
    function onLibraryRevisionChanged() { root.reload() }
  }

  function reload() {
    if (!item || !item.id) return
    loading = true
    service.call("item.get", { id: item.id }, function(result, error) {
      if (!root) return
      root.loading = false
      if (error) { root.error = error.message; return }
      root.error = ""
      root.details = result
      root.loadRelated()
    })
  }

  function loadRelated() {
    if (!details) return
    if (details.type === "Series" || details.type === "Episode") {
      var sid = details.type === "Series" ? details.id : details.seriesId
      if (!sid) return
      service.call("show.seasons", { id: sid }, function(result, error) {
        if (!root || error) return
        root.seasons = result
        if (!root.seasonId) {
          var want = details.type === "Episode" ? details.seasonId : details.nextUp ? details.nextUp.seasonId : ""
          root.seasonId = want || (result.length > 0 ? result[0].id : "")
        }
        root.loadEpisodes()
      })
    }
    if (details.type === "Movie" || details.type === "Series") {
      service.call("item.similar", { id: details.id }, function(result, error) {
        if (!root || error) return
        root.similar = result
      })
    }
  }

  function loadEpisodes() {
    if (!seriesId || !seasonId) return
    service.call("show.episodes", { id: seriesId, seasonId: seasonId }, function(result, error) {
      if (!root || error) return
      root.episodes = result
    })
  }

  function selectSeason(season) {
    if (!season || season.id === seasonId) return
    seasonId = season.id
    episodes = []
    loadEpisodes()
  }

  function patch(id, user) {
    if (details && details.id === id) {
      var next = Object.assign({}, details)
      next.user = Object.assign({}, details.user, user)
      details = next
    }
    if (item && item.id === id) {
      var it = Object.assign({}, item)
      it.user = Object.assign({}, item.user || {}, user)
      item = it
    }
    episodes = Items.patchUser(episodes, id, user)
    similar = Items.patchUser(similar, id, user)
    seasons = Items.patchUser(seasons, id, user)
  }

  readonly property var currentSeason: seasons.filter(function(s) { return s.id === root.seasonId })[0] || null
  readonly property int nextUpIndex: {
    var target = playTarget
    if (!target) return 0
    for (var i = 0; i < episodes.length; i++) if (episodes[i].id === target.id) return i
    return 0
  }

  readonly property var people: details && details.people ? details.people.map(function(p) {
    return { id: p.id, name: p.name, role: p.role || p.type, type: "Person", images: { primary: p.image } }
  }) : []

  readonly property var rows: {
    var out = []
    if (episodes.length > 0 && (isSeries || isEpisode)) {
      out.push({ key: "episodes:" + seasonId, title: isEpisode ? "More from " + (currentSeason ? currentSeason.name : "this season") : (currentSeason ? currentSeason.name : "Episodes"),
        items: episodes, shape: "landscape", episodeTitles: true, startIndex: isEpisode ? Math.max(0, episodes.map(function(e) { return e.id }).indexOf(shown.id)) : nextUpIndex })
    }
    if (seasons.length > 1) out.push({ key: "seasons", title: "Seasons", items: seasons, shape: "poster", cardWidth: theme.space(120) })
    if (people.length > 0) out.push({ key: "people", title: "Cast & crew", items: people, shape: "poster", cardWidth: theme.space(110) })
    if (similar.length > 0) out.push({ key: "similar", title: "More like this", items: similar, shape: "poster" })
    return out
  }

  function currentAnchor() {
    return page.currentCard()
  }

  function currentTarget() {
    if (page.headerActive) return shown
    var row = page.currentRow()
    if (row && row.key === "people") return null
    return page.currentItem()
  }

  function activate(card, row) {
    if (!card) return
    if (row && row.key === "seasons") {
      selectSeason(card)
      page.rowIndex = 0
      page.moved = true
      return
    }
    if (row && row.key === "people") {
      openGrid({ kind: "grid", title: card.name, personId: card.id, types: "Movie,Series", sort: "released", descending: true, recursive: true })
      return
    }
    openItem(card)
  }

  function playShown(restart) {
    if (!playTarget) return
    var options = { restart: restart === true }
    if (playTarget.id === shown.id) {
      if (audioIndex !== null) options.audioIndex = audioIndex
      if (subtitleIndex !== null) options.subtitleIndex = subtitleIndex
    }
    // Picture subtitles the server may not burn in: only mpv shows them.
    var picked = subtitleStreams.filter(function(s) { return s.index === root.subtitleIndex })[0]
    if (picked && /^(pgssub|pgs|dvdsub|dvbsub|vobsub)$/i.test(picked.codec || "") && service.playbackPrefs.allowTranscoding !== true && service.mpvAvailable) {
      playInMpv(playTarget, options)
      return
    }
    playWith(playTarget, options)
  }

  function handleKey(id) {
    if (page.handleKey(id)) return
    switch (id) {
    case "open":
      if (page.headerActive) playShown(false)
      else activate(page.currentItem(), page.currentRow())
      return
    }
  }

  function chooseAudio(anchor) {
    var items = audioStreams.map(function(s) {
      return { id: String(s.index), label: Format.streamLabel(s), icon: (root.audioIndex === null ? s.index === root.source.defaultAudio : s.index === root.audioIndex) ? "check" : "" }
    })
    showMenu(items, anchor, function(id) { root.audioIndex = Number(id) })
  }

  function chooseSubtitles(anchor) {
    var current = subtitleIndex === null ? (source && source.defaultSubtitle !== null && source.defaultSubtitle >= 0 ? source.defaultSubtitle : -1) : subtitleIndex
    var items = [{ id: "-1", label: "Off", icon: current === -1 ? "check" : "" }].concat(subtitleStreams.map(function(s) {
      var mpvOnly = s.codec && /^(pgssub|pgs|dvdsub|dvbsub|vobsub)$/i.test(s.codec) && root.service.playbackPrefs.allowTranscoding !== true
      return { id: String(s.index), label: Format.streamLabel(s) + (mpvOnly ? " (plays in mpv)" : ""), icon: s.index === current ? "check" : "" }
    }))
    showMenu(items, anchor, function(id) { root.subtitleIndex = Number(id) })
  }

  function streamName(list, index, fallback) {
    for (var i = 0; i < list.length; i++) if (list[i].index === index) return list[i].language ? String(list[i].language).toUpperCase() : Format.streamLabel(list[i])
    return fallback
  }

  BrowsePage {
    id: page
    anchors.fill: parent
    theme: root.theme
    service: root.service
    rows: root.rows
    headerFocusable: true
    header: headerComponent
    onOpened: function(card, row) { root.activate(card, row) }
    onPlayed: function(card) { root.playItem(card, false) }
    onMenuRequested: function(card, anchor, x, y) { if (card.type !== "Person") root.menuItem(card, anchor, x, y) }
  }

  Component {
    id: headerComponent
    Item {
      id: head
      width: parent ? parent.width : 0
      height: Math.max(root.height * 0.62, info.implicitHeight + root.theme.space(120))

      Backdrop {
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.min(parent.height, root.height * 0.7)
        theme: root.theme
        service: root.service
        image: root.shown && root.shown.images ? root.shown.images.backdrop || root.shown.images.thumb : null
        requestWidth: Math.min(2560, head.width * 1.25)
      }

      Column {
        id: info
        anchors.left: parent.left
        anchors.leftMargin: root.theme.space(32)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.theme.space(6)
        width: Math.min(parent.width - root.theme.space(64), root.theme.space(760))
        spacing: root.theme.space(10)

        // An episode names its show first; the name opens the show.
        Text {
          visible: root.isEpisode && !!root.shown.seriesName
          text: root.shown && root.shown.seriesName ? root.shown.seriesName + "  ›" : ""
          textFormat: Text.PlainText
          color: seriesLink.containsMouse ? root.theme.accent : root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.title
          font.bold: true
          MouseArea { id: seriesLink; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openSeries(root.shown.seriesId) }
        }
        Image {
          id: logo
          visible: !root.isEpisode && status === Image.Ready
          width: Math.min(parent.width, root.theme.space(420))
          height: root.theme.space(120)
          fillMode: Image.PreserveAspectFit
          horizontalAlignment: Image.AlignLeft
          source: !root.isEpisode && root.shown && root.shown.images ? root.service.imageUrl(root.shown.images.logo, "Logo", 700) : ""
          asynchronous: true
        }
        Text {
          visible: root.isEpisode || logo.status !== Image.Ready
          width: parent.width
          text: root.shown ? (root.isEpisode ? Format.episodeCode(root.shown) + "  " : "") + (root.shown.name || "") : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.isEpisode ? root.theme.heading : root.theme.display
          font.bold: true
        }
        Text {
          width: parent.width
          text: {
            var parts = [Format.metaLine(root.shown)]
            if (root.playTarget && root.playTarget.runtime && !root.isSeries) {
              var left = root.playTarget.runtime - (root.playTarget.user && !root.playTarget.user.played ? (root.playTarget.user.position || 0) : 0)
              parts.push(Format.endsAt(left))
            }
            return parts.filter(function(s) { return s !== "" }).join("  ·  ")
          }
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        Flow {
          width: parent.width
          spacing: root.theme.space(6)
          visible: !!root.details && root.details.genres && root.details.genres.length > 0
          Repeater {
            model: root.details && root.details.genres ? root.details.genres.slice(0, 6) : []
            delegate: Rectangle {
              required property var modelData
              height: root.theme.space(24)
              width: genreText.implicitWidth + root.theme.space(18)
              radius: height / 2
              color: genreMouse.containsMouse ? root.theme.hoverFill : root.theme.alpha(root.theme.background, 0.5)
              border.width: root.theme.borderWidth
              border.color: root.theme.border
              Text {
                id: genreText
                anchors.centerIn: parent
                text: modelData
                textFormat: Text.PlainText
                color: root.theme.foreground
                font.family: root.theme.font
                font.pixelSize: root.theme.caption
              }
              MouseArea {
                id: genreMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openGrid({ kind: "grid", title: modelData, genres: [modelData],
                  types: root.isSeries ? "Series" : root.isEpisode ? "Series" : "Movie", recursive: true, sort: "name" })
              }
            }
          }
        }

        Row {
          spacing: root.theme.space(8)
          PlayButton {
            visible: root.playTarget !== null
            theme: root.theme
            item: root.playTarget
            current: page.headerActive
            onClicked: root.playShown(false)
          }
          IconButton {
            visible: !!root.playTarget && Format.progress(root.playTarget) > 0
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: "restart"
            tooltip: "Play from the start (Shift+P)"
            onClicked: root.playShown(true)
          }
          IconButton {
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: root.shown && root.shown.user && root.shown.user.played ? "playedOn" : "played"
            color: root.shown && root.shown.user && root.shown.user.played ? root.theme.accent : root.theme.foreground
            tooltip: root.shown && root.shown.user && root.shown.user.played ? "Watched. Mark as not watched (w)" : "Mark as watched (w)"
            onClicked: root.toggleWatched(root.shown)
          }
          IconButton {
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: root.shown && root.shown.user && root.shown.user.favorite ? "favoriteOn" : "favorite"
            color: root.shown && root.shown.user && root.shown.user.favorite ? root.theme.urgent : root.theme.foreground
            tooltip: root.shown && root.shown.user && root.shown.user.favorite ? "A favourite. Remove from favourites (f)" : "Add to favourites (f)"
            onClicked: root.toggleFavorite(root.shown)
          }
          DownloadButton {
            visible: !root.isSeries && root.playTarget !== null
            theme: root.theme
            service: root.service
            item: root.shown
            fileSize: root.source && root.source.size ? root.source.size : 0
            anchors.verticalCenter: parent.verticalCenter
            onClicked: function(anchor) { root.downloadClicked(root.shown, anchor) }
          }
          IconButton {
            visible: root.playTarget !== null && root.service.mpvAvailable
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: "external"
            tooltip: "Play in mpv (m)"
            onClicked: root.playInMpv(root.playTarget, { audioIndex: root.audioIndex, subtitleIndex: root.subtitleIndex })
          }
          IconButton {
            visible: !!root.details && root.details.trailers && root.details.trailers.length > 0
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: "trailer"
            tooltip: "Watch the trailer in your browser"
            onClicked: Qt.openUrlExternally(root.details.trailers[0])
          }
          IconButton {
            id: moreButton
            theme: root.theme
            size: root.theme.space(40)
            round: true
            anchors.verticalCenter: parent.verticalCenter
            icon: "moreHorizontal"
            tooltip: "More (.)"
            onClicked: root.menuItem(root.shown, moreButton, 0, moreButton.height)
          }
        }

        // Downloaded: it plays from this computer, server or not.
        Row {
          readonly property var dl: root.shown ? root.service.downloadOf(root.shown.id) : null
          visible: !!dl && (dl.state === "done" || dl.state === "missing")
          spacing: root.theme.space(6)
          Glyph {
            name: parent.dl && parent.dl.state === "missing" ? "error" : "downloaded"
            size: root.theme.small + 1
            color: parent.dl && parent.dl.state === "missing" ? root.theme.urgent : root.theme.accent
            font.family: root.theme.font
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: !parent.dl ? "" : parent.dl.state === "missing" ? (parent.dl.error || "The downloaded file was removed") + "; this streams from the server"
              : "Downloaded · plays from this computer" + (root.details && root.details.offline ? " (the server is out of reach)" : "")
            textFormat: Text.PlainText
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // What will play: the tracks, chosen before it starts.
        Row {
          visible: root.audioStreams.length > 0 || root.subtitleStreams.length > 0
          spacing: root.theme.space(8)
          TextButton {
            id: audioButton
            visible: root.audioStreams.length > 1
            theme: root.theme
            icon: "audio"
            pill: true
            fontSize: root.theme.small
            text: "Audio: " + root.streamName(root.audioStreams, root.audioIndex === null ? (root.source ? root.source.defaultAudio : -1) : root.audioIndex, "Default") + "..."
            onClicked: root.chooseAudio(audioButton)
          }
          TextButton {
            id: subtitleButton
            visible: root.subtitleStreams.length > 0
            theme: root.theme
            icon: "subtitles"
            pill: true
            fontSize: root.theme.small
            text: {
              var current = root.subtitleIndex === null ? (root.source && root.source.defaultSubtitle !== null ? root.source.defaultSubtitle : -1) : root.subtitleIndex
              return "Subtitles: " + (current === null || current < 0 ? "Off" : root.streamName(root.subtitleStreams, current, "On")) + "..."
            }
            onClicked: root.chooseSubtitles(subtitleButton)
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Format.videoTag(root.videoStream)
            textFormat: Text.PlainText
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }

        Text {
          visible: !!root.details && !!root.details.tagline
          width: parent.width
          text: root.details && root.details.tagline ? root.details.tagline : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          font.italic: true
        }
        Text {
          id: overview
          width: parent.width
          visible: text !== ""
          text: root.shown && root.shown.overview ? root.shown.overview : ""
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          maximumLineCount: root.overviewOpen ? 100 : 4
          elide: Text.ElideRight
          color: root.theme.foreground
          opacity: 0.9
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          lineHeight: 1.25
          MouseArea {
            anchors.fill: parent
            cursorShape: overview.truncated || root.overviewOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.overviewOpen = !root.overviewOpen
          }
        }
        Text {
          visible: !!root.details && (root.directors !== "" || (root.details.studios && root.details.studios.length > 0))
          width: parent.width
          text: [root.directors ? "Directed by " + root.directors : "", root.details && root.details.studios ? root.details.studios.slice(0, 3).join(", ") : ""].filter(function(s) { return s !== "" }).join("  ·  ")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.caption
        }
        Row {
          visible: !!root.details && root.details.links && Object.keys(root.details.links).length > 0
          spacing: root.theme.space(12)
          Repeater {
            model: root.details && root.details.links ? Object.keys(root.details.links) : []
            delegate: Text {
              required property var modelData
              text: (modelData === "Imdb" ? "IMDb" : modelData === "Tmdb" ? "TMDB" : modelData) + " ↗"
              textFormat: Text.PlainText
              color: linkMouse.containsMouse ? root.theme.accent : root.theme.dim
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
              MouseArea { id: linkMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(root.details.links[modelData]) }
            }
          }
        }
        Text {
          visible: root.error !== ""
          text: root.error
          textFormat: Text.PlainText
          color: root.theme.urgent
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
      }
    }
  }

  readonly property string directors: details && details.people ? details.people.filter(function(p) { return p.type === "Director" }).map(function(p) { return p.name }).slice(0, 2).join(", ") : ""
}
