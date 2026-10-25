import QtQuick

// "Are you sure" for actions that cannot be taken back. The confirming
// button names the action, never "OK".
Sheet {
  id: root

  property string message: ""
  property string confirmText: "Delete"
  property bool danger: true
  property var onConfirm: null

  function ask(options) {
    title = options.title || ""
    subtitle = ""
    message = options.message || ""
    confirmText = options.confirmText || "Delete"
    danger = options.danger !== false
    onConfirm = options.onConfirm || null
    opened = true
    Qt.callLater(function() { cancelButton.forceActiveFocus() })
  }

  function confirm() {
    opened = false
    if (typeof onConfirm === "function") onConfirm()
  }

  Column {
    width: parent.width
    spacing: root.theme.space(14)

    Text {
      width: parent.width
      text: root.message
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      lineHeight: 1.25
    }

    Row {
      anchors.right: parent.right
      spacing: root.theme.space(8)
      TextButton {
        id: cancelButton
        theme: root.theme
        text: "Cancel"
        onClicked: root.close()
        Keys.onReturnPressed: root.close()
        Keys.onEnterPressed: root.close()
      }
      TextButton {
        id: confirmButton
        theme: root.theme
        text: root.confirmText
        primary: !root.danger
        danger: root.danger
        onClicked: root.confirm()
        Keys.onReturnPressed: root.confirm()
        Keys.onEnterPressed: root.confirm()
      }
    }
  }
}
