import QtQuick

// Shown until the backend runs: while its binary is checked or downloaded,
// and when that fails — with what went wrong and what to do about it.
Rectangle {
  id: root
  required property var theme
  required property var service
  color: theme.background

  readonly property string state_: !service ? "checking" : service.backendState
  readonly property string failure: service && service.backend ? service.backend.failure : ""
  readonly property bool problem: state_ === "failed" || (state_ === "ready" && failure !== "")

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(520))
    spacing: root.theme.space(12)
    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: root.problem ? "warning" : root.state_ === "downloading" ? "download" : "logo"
      size: root.theme.display * 1.6
      color: root.problem ? root.theme.urgent : root.theme.accent
      font.family: root.theme.font
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.state_ === "downloading" ? "Downloading Omafin's backend…"
        : root.state_ === "failed" ? "Omafin's backend is not installed"
        : root.failure ? "Omafin's backend stopped"
        : "Starting…"
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.title
    }
    TextEdit {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      readOnly: true
      selectByMouse: true
      wrapMode: Text.Wrap
      text: root.state_ === "downloading" ? "The build for version " + root.service.version + " comes from the project's releases and is checked before use."
        : root.state_ === "failed" ? (root.service.backendMessage ? root.service.backendMessage + "\n\n" : "")
            + "To build it on this computer instead, run:\n\n" + root.service.pluginDir + "/install.sh --build"
        : root.failure
      color: root.state_ === "failed" ? root.theme.urgent : root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      visible: root.state_ === "failed" && !root.service.devCheckout
      anchors.horizontalCenter: parent.horizontalCenter
      theme: root.theme
      text: "Try again"
      icon: "refresh"
      onClicked: root.service.fetchBinary()
    }
  }
}
