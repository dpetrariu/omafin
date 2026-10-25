import QtQuick
import "../lib/Icons.js" as Icons

// One icon from the Nerd Font set, by name.
//
// `optical`: centre the icon's drawn shape rather than the space the font
// reserves for it. Nerd Font icons hang off their advance by different
// amounts (most sit 1-3 px right of centre at button sizes, the "more"
// dots low), which shows in a round button. Measured per icon, then
// nudged with a transform, so layout is unchanged.
Text {
  id: root
  property string name: ""
  property real size: 14
  property bool optical: false
  text: Icons.glyph(name)
  font.pixelSize: size
  textFormat: Text.PlainText
  renderType: Text.NativeRendering
  horizontalAlignment: Text.AlignHCenter
  verticalAlignment: Text.AlignVCenter

  TextMetrics { id: ink; font: root.font; text: root.optical ? root.text : "" }
  FontMetrics { id: metrics; font: root.font }
  transform: Translate {
    x: !root.optical || ink.tightBoundingRect.width === 0 ? 0
      : root.width / 2 - ((root.width - ink.advanceWidth) / 2 + ink.tightBoundingRect.x + ink.tightBoundingRect.width / 2)
    y: !root.optical || ink.tightBoundingRect.height === 0 ? 0
      : root.height / 2 - ((root.height - metrics.height) / 2 + metrics.ascent + ink.tightBoundingRect.y + ink.tightBoundingRect.height / 2)
  }
}
