import QtQuick
import "../lib/Icons.js" as Icons

// One icon from the Nerd Font set, by name.
//
// `optical`: centre the icon's drawn shape in its parent rather than the
// text box. Nerd Font icons hang off their advance by different amounts
// (most 1-3 px right of centre at button sizes), and the crisp renderer
// puts the baseline on a whole pixel, which leaves a centred box up to a
// pixel high or low depending on the size. So an optical icon is placed by
// its measured centre (Icons.optical) and its baseline lands on a whole
// pixel. Layout is unchanged; only a transform moves it.
Text {
  id: root
  property string name: ""
  property real size: 14
  property bool optical: false
  readonly property var ink: optical ? Icons.optical(name) : null
  text: Icons.glyph(name)
  font.pixelSize: size
  textFormat: Text.PlainText
  renderType: Text.NativeRendering
  horizontalAlignment: Text.AlignHCenter
  verticalAlignment: Text.AlignVCenter

  transform: Translate {
    x: !root.ink || !root.parent ? 0
      : Math.round(root.parent.width / 2 - root.width / 2 - root.ink[0] * root.size) - root.x
    y: !root.ink || !root.parent ? 0
      : Math.round(root.parent.height / 2 + root.ink[1] * root.size) - root.baselineOffset - root.y
  }
}
