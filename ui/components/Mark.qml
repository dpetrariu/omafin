import QtQuick
import QtQuick.Window
import "../lib/Mark.js" as MarkSvg

// Omafin's mark (lib/Mark.js) in one colour, like a glyph: drawn at the size
// it is shown, in physical pixels, with the colour's alpha as its opacity.
Item {
  id: root
  property real size: 14
  property color color: "white"
  implicitWidth: size
  implicitHeight: size

  Image {
    anchors.fill: parent
    source: MarkSvg.url(root.color.r, root.color.g, root.color.b)
    sourceSize.width: Math.ceil(root.size * Screen.devicePixelRatio)
    sourceSize.height: Math.ceil(root.size * Screen.devicePixelRatio)
    fillMode: Image.PreserveAspectFit
    opacity: root.color.a
    smooth: true
  }
}
