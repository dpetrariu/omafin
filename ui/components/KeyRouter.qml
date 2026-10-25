import QtQuick
import QtQml
import "../keys/Keymap.js" as Keymap

// Turns the key table into live Shortcuts for the current context and reports
// what was pressed by id. An Instantiator, because a Shortcut is a QtObject and
// a Repeater only builds Items.
Item {
  id: root

  property string context: "grid"

  signal triggered(string id, string sequence)

  Instantiator {
    model: Keymap.sequencesFor(root.context)

    delegate: Shortcut {
      required property var modelData
      sequence: modelData.sequence
      context: Qt.WindowShortcut
      autoRepeat: modelData.repeat !== false
      onActivated: root.triggered(modelData.id, modelData.sequence)
    }
  }
}
