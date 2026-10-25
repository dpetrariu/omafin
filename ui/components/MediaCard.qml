import QtQuick
import "../lib/Format.js" as Format

// One film, show, season, episode, collection or person: its picture and
// two lines under it. State is drawn as shapes, not colour alone: a check
// for watched, a count for unwatched episodes, a bar for progress and a
// heart for favourites. Hovering offers Play without opening the page.
Item {
  id: root

  required property var theme
  required property var service
  property var item: null
  // "poster" (2:3), "landscape" (16:9) or "square" (people, folders).
  property string shape: "poster"
  property bool current: false
  property bool showText: true
  // Episodes in a show's own list need no show name above them.
  property bool episodeTitles: false

  signal clicked()
  signal playClicked()
  signal menuRequested(Item anchor, real x, real y)

  readonly property real ratio: shape === "landscape" ? 16 / 9 : shape === "square" ? 1 : 2 / 3
  readonly property real imageHeight: Math.round(width / ratio)
  readonly property bool playable: Format.isPlayable(item)
  readonly property real progress: Format.progress(item)
  readonly property bool hovered: mouse.containsMouse || playMouse.containsMouse

  implicitWidth: theme.space(shape === "landscape" ? 260 : 150)
  implicitHeight: imageHeight + (showText ? texts.implicitHeight + theme.space(8) : 0)

  function pick() {
    if (!item || !item.images) return { image: null, kind: "Primary" }
    var im = item.images
    if (shape === "landscape") {
      if (item.type === "Episode" && im.primary) return { image: im.primary, kind: "Primary" }
      if (im.thumb) return { image: im.thumb, kind: "Thumb" }
      if (im.backdrop) return { image: im.backdrop, kind: "Backdrop" }
      return { image: im.primary, kind: "Primary" }
    }
    if (item.type === "Episode" && im.series) return { image: im.series, kind: "Primary" }
    return { image: im.primary || im.series, kind: "Primary" }
  }
  readonly property var picked: pick()

  Rectangle {
    id: frame
    width: parent.width
    height: root.imageHeight
    radius: root.theme.radius
    color: root.theme.raised
    clip: true

    Glyph {
      anchors.centerIn: parent
      visible: picture.status !== Image.Ready
      name: !root.item ? "noImage" : root.item.type === "Series" || root.item.type === "Season" ? "shows"
        : root.item.type === "Person" ? "person" : root.item.type === "BoxSet" ? "collections"
        : root.item.isFolder ? Format.viewIcon(root.item.collectionType) : "movies"
      size: Math.min(parent.width, parent.height) * 0.28
      color: root.theme.faint
      font.family: root.theme.font
    }

    Image {
      id: picture
      anchors.fill: parent
      source: root.service.imageUrl(root.picked.image, root.picked.kind, root.width * 1.5)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      sourceSize.width: Math.round(root.width * 1.5)
      opacity: status === Image.Ready ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180 } }
    }

    // A landscape card without its own still names itself on the picture.
    Rectangle {
      visible: root.shape === "landscape" && picture.status === Image.Ready && root.picked.kind !== "Primary" && root.item && root.item.images && !root.item.images.logo
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: parent.height * 0.5
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.6) }
      }
    }

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, root.hovered ? 0.25 : 0)
      Behavior on color { ColorAnimation { duration: 150 } }
    }

    // Watched, or how many episodes are left.
    Rectangle {
      readonly property int unplayed: root.item && root.item.user && root.item.user.unplayed ? root.item.user.unplayed : 0
      readonly property bool played: !!root.item && !!root.item.user && root.item.user.played === true
      visible: played || unplayed > 0
      anchors { top: parent.top; right: parent.right; margins: root.theme.space(6) }
      height: root.theme.space(22)
      width: played ? height : Math.max(height, countText.implicitWidth + root.theme.space(12))
      radius: height / 2
      color: root.theme.accent
      Glyph {
        visible: parent.played
        anchors.centerIn: parent
        name: "check"
        size: root.theme.small + 1
        color: root.theme.background
        font.family: root.theme.font
      }
      Text {
        id: countText
        visible: !parent.played
        anchors.centerIn: parent
        text: String(parent.unplayed)
        color: root.theme.background
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
        font.bold: true
      }
    }

    Rectangle {
      visible: !!root.item && !!root.item.user && root.item.user.favorite === true
      anchors { left: parent.left; bottom: parent.bottom; margins: root.theme.space(6) }
      anchors.bottomMargin: root.theme.space(root.progress > 0 ? 12 : 6)
      width: root.theme.space(22)
      height: width
      radius: width / 2
      color: Qt.rgba(0, 0, 0, 0.55)
      Glyph {
        anchors.centerIn: parent
        name: "favoriteOn"
        size: root.theme.small + 1
        color: root.theme.urgent
        font.family: root.theme.font
      }
    }

    Rectangle {
      visible: root.progress > 0
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: root.theme.space(4)
      color: Qt.rgba(0, 0, 0, 0.5)
      Rectangle {
        width: parent.width * root.progress
        height: parent.height
        color: root.theme.accent
      }
    }

    // Play from the card, without opening the page.
    Rectangle {
      visible: root.playable && (root.hovered || root.current)
      anchors.centerIn: parent
      width: root.theme.space(44)
      height: width
      radius: width / 2
      color: playMouse.containsMouse ? root.theme.accent : Qt.rgba(0, 0, 0, 0.6)
      border.width: root.theme.borderWidth
      border.color: Qt.rgba(1, 1, 1, 0.6)
      Glyph {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root.theme.space(2)
        name: "play"
        size: root.theme.heading
        color: playMouse.containsMouse ? root.theme.background : "white"
        font.family: root.theme.font
      }
      MouseArea {
        id: playMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.playClicked()
      }
    }
  }

  // The keyboard cursor: a thick ring, so it shows on any picture.
  Rectangle {
    visible: root.current
    x: -root.theme.space(3)
    y: -root.theme.space(3)
    width: frame.width + root.theme.space(6)
    height: frame.height + root.theme.space(6)
    radius: root.theme.radius + root.theme.space(3)
    color: "transparent"
    border.width: root.theme.space(3)
    border.color: root.theme.accent
  }

  Column {
    id: texts
    visible: root.showText
    anchors.top: frame.bottom
    anchors.topMargin: root.theme.space(6)
    width: parent.width
    spacing: root.theme.space(1)
    Text {
      width: parent.width
      text: root.episodeTitles && root.item && root.item.type === "Episode"
        ? (Format.episodeCode(root.item) ? Format.episodeCode(root.item).replace(/^S\d+ · /, "") + ". " : "") + (root.item.name || "")
        : Format.cardTitle(root.item)
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      font.bold: root.current
    }
    Text {
      width: parent.width
      text: root.episodeTitles && root.item && root.item.type === "Episode"
        ? [Format.runtime(root.item.runtime), Format.minutesLeft(root.item)].filter(function(s) { return s !== "" }).join("  ·  ")
        : root.progress > 0 && root.item.type !== "Episode" ? Format.minutesLeft(root.item) : Format.cardSubtitle(root.item)
      visible: text !== ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    z: -1
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(m) {
      if (m.button === Qt.RightButton) root.menuRequested(root, m.x, m.y)
      else root.clicked()
    }
  }
}
