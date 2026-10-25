import QtQuick
import qs.Ui

// The search field in the header. Typing changes the key context, so bare
// letters stop being actions while a query is written.
Item {
  id: root

  required property var theme
  property alias text: field.text
  readonly property bool focused: field.activeFocus
  property string placeholder: "Search films, shows, episodes and people"

  signal submitted(string text)
  signal cancelled()

  implicitHeight: theme.space(32)

  function focusField() {
    field.forceActiveFocus()
    field.selectAll()
  }

  function clear() { field.text = "" }

  TextField {
    id: field
    anchors.fill: parent
    leftPadding: root.theme.space(32)
    placeholderText: root.placeholder
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    onAccepted: root.submitted(text.trim())
    Keys.onEscapePressed: function(event) {
      event.accepted = true
      root.cancelled()
    }
  }

  Glyph {
    x: root.theme.space(10)
    anchors.verticalCenter: parent.verticalCenter
    name: "search"
    size: root.theme.icon
    color: root.theme.dim
    font.family: root.theme.font
  }
}
