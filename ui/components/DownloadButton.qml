import QtQuick
import QtQuick.Shapes
import qs.Ui
import "../lib/Format.js" as Format

// Download a title, see it coming, and delete it again: a round button
// beside Play. Nothing yet: a download arrow. On its way: a ring that fills,
// with the percentage inside. Done: a bin. Paused, failed or deleted behind
// Omafin's back: their own icon, and the tooltip says what happened.
Item {
  id: root

  required property var theme
  required property var service
  property var item: null
  property real size: theme.space(40)
  // The file's size when not downloaded yet, for the tooltip.
  property real fileSize: 0

  readonly property var entry: item ? service.downloadOf(item.id) : null
  readonly property string state_: entry ? entry.state : "none"
  readonly property real progress: entry && entry.size > 0 ? Math.min(1, entry.bytes / entry.size) : 0
  readonly property bool ringing: state_ === "downloading" || state_ === "queued" || state_ === "paused"

  signal clicked(Item anchor)

  implicitWidth: size
  implicitHeight: size

  Rectangle {
    anchors.fill: parent
    anchors.margins: root.theme.space(1)
    radius: width / 2
    color: mouse.pressed ? root.theme.pressedFill : mouse.containsMouse ? root.theme.hoverFill : root.theme.alpha(root.theme.background, 0.45)
    border.width: root.ringing ? 0 : root.theme.borderWidth
    border.color: root.theme.border
  }

  // The ring: a faint track and the part already here.
  Shape {
    visible: root.ringing
    anchors.fill: parent
    anchors.margins: root.theme.space(2)
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      strokeColor: root.theme.border
      strokeWidth: root.theme.space(2.5)
      fillColor: "transparent"
      PathAngleArc {
        centerX: (root.width - root.theme.space(4)) / 2; centerY: centerX
        radiusX: centerX - root.theme.space(1.5); radiusY: radiusX
        startAngle: -90; sweepAngle: 360
      }
    }
    ShapePath {
      strokeColor: root.state_ === "paused" ? root.theme.dim : root.theme.accent
      strokeWidth: root.theme.space(2.5)
      capStyle: ShapePath.RoundCap
      fillColor: "transparent"
      PathAngleArc {
        centerX: (root.width - root.theme.space(4)) / 2; centerY: centerX
        radiusX: centerX - root.theme.space(1.5); radiusY: radiusX
        startAngle: -90; sweepAngle: 360 * Math.max(0.001, root.progress)
      }
    }
  }

  // Downloading: the percentage; otherwise an icon for the state.
  Text {
    visible: root.state_ === "downloading"
    anchors.centerIn: parent
    text: Math.floor(root.progress * 100) + "%"
    color: root.theme.foreground
    font.family: root.theme.font
    font.pixelSize: root.theme.caption
    font.bold: true
  }
  Glyph {
    visible: root.state_ !== "downloading"
    anchors.centerIn: parent
    optical: true
    name: root.state_ === "done" ? "trash"
      : root.state_ === "paused" ? "pause"
      : root.state_ === "failed" || root.state_ === "missing" ? "error"
      : "download"
    size: root.theme.icon
    color: root.state_ === "failed" || root.state_ === "missing" ? root.theme.urgent
      : root.state_ === "done" && mouse.containsMouse ? root.theme.urgent
      : root.state_ === "queued" ? root.theme.dim
      : root.theme.foreground
    font.family: root.theme.font
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked(root)
  }

  PanelToolTip {
    visible: mouse.containsMouse
    text: {
      var e = root.entry
      // The entry can go a moment before the state follows.
      if (!e && root.state_ !== "none") return ""
      switch (root.state_) {
      case "none": return "Download" + (root.fileSize > 0 ? " (" + Format.bytes(root.fileSize) + ")" : "") + " to " + (root.service.downloadsRoot || "~/Videos/Omafin")
      case "queued": return e.error ? e.error : "Waiting to download"
      case "downloading": return "Downloading · " + Format.downloadLine(e) + " — click to pause or cancel"
      case "paused": return (e.error || "Paused") + " · " + Math.floor(root.progress * 100) + "% here — click to resume or cancel"
      case "failed": return e.error + " — click to try again or cancel"
      case "missing": return "The downloaded file was removed — click to download it again or remove it"
      case "done": return "Delete download... (" + Format.bytes(e.size) + ")"
      }
      return ""
    }
  }
}
