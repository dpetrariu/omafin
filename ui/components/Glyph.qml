import QtQuick
import "../lib/Icons.js" as Icons

// One icon from the Nerd Font set, by name.
Text {
  id: root
  property string name: ""
  property real size: 14
  text: Icons.glyph(name)
  font.pixelSize: size
  textFormat: Text.PlainText
  renderType: Text.NativeRendering
  horizontalAlignment: Text.AlignHCenter
  verticalAlignment: Text.AlignVCenter
}
