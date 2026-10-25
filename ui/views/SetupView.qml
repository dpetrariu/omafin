import QtQuick
import qs.Ui
import "../components"

// First run: the server address, then signing in, with Quick Connect (a
// code you approve in another Jellyfin app) when the server offers it, or
// a user name and password.
Item {
  id: root
  required property var theme
  required property var service

  readonly property bool isForm: true
  property var server: null          // what auth.probe found
  property string mode: "password"   // quick | password
  property string code: ""
  property string error: ""
  property bool busy: false
  // For the UI tests, which fill the form as a person would.
  property alias address: url.text
  property alias userName: user.text
  property alias passwordText: password.text

  Component.onCompleted: {
    url.text = service.settings && service.settings.serverUrl ? service.settings.serverUrl : ""
    url.forceActiveFocus()
  }
  Component.onDestruction: if (code !== "") service.call("auth.quickConnectCancel", {}, function() {})

  function probe() {
    error = ""
    if (!url.text.trim()) { error = "Enter your Jellyfin address"; return }
    busy = true
    service.call("auth.probe", { url: url.text }, function(r, e) {
      if (!root) return
      root.busy = false
      if (e) { root.error = e.message; return }
      root.server = r
      root.mode = r.quickConnect ? "quick" : "password"
      if (r.quickConnect) root.startQuickConnect()
      else Qt.callLater(function() { if (root) user.forceActiveFocus() })
    })
  }

  function startQuickConnect() {
    error = ""
    code = ""
    service.call("auth.quickConnectStart", { url: server.url }, function(r, e) {
      if (!root) return
      if (e) { root.error = e.message; root.mode = "password"; return }
      root.code = r.code
      poll.start()
    })
  }

  Timer {
    id: poll
    interval: 2000
    repeat: true
    running: false
    onTriggered: root.service.call("auth.quickConnectPoll", {}, function(r, e) {
      if (!root) return
      if (e) { poll.stop(); root.error = e.message; root.code = ""; return }
      if (r.state === "signedIn") {
        poll.stop()
        root.code = ""
        root.service.applySettingsResponse(r.settings)
        root.service.refreshServer()
      }
    })
  }

  function signIn() {
    error = ""
    if (!user.text.trim()) { error = "Enter your user name"; return }
    busy = true
    service.call("auth.signIn", { url: server.url, username: user.text, password: password.text }, function(r, e) {
      if (!root) return
      root.busy = false
      if (e) { root.error = e.message; password.selectAll(); password.forceActiveFocus(); return }
      password.text = ""
      root.service.applySettingsResponse(r)
      root.service.refreshServer()
    })
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(480))
    spacing: root.theme.space(14)

    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: "logo"
      size: root.theme.display * 2
      color: root.theme.accent
      font.family: root.theme.font
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.server ? "Sign in to " + (root.server.name || "Jellyfin") : "Connect to your Jellyfin"
      textFormat: Text.PlainText
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.heading
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.server
        ? "Jellyfin " + (root.server.version || "") + " at " + root.server.url + ". Omafin keeps the session in your keyring."
        : "Omafin plays your films and shows from a Jellyfin server. Enter its address, the same one you open in a browser."
      textFormat: Text.PlainText
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      lineHeight: 1.25
    }

    // Step one: the address.
    Column {
      visible: !root.server
      width: parent.width
      spacing: root.theme.space(10)
      Text { text: "Server address"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField {
        id: url
        width: parent.width
        placeholderText: "http://192.168.1.10:8096 or https://tv.example.com"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        onAccepted: root.probe()
      }
      TextButton {
        anchors.right: parent.right
        theme: root.theme
        text: "Continue"
        primary: true
        busy: root.busy
        onClicked: root.probe()
      }
    }

    // Step two, Quick Connect: a code to approve elsewhere.
    Column {
      visible: !!root.server && root.mode === "quick"
      width: parent.width
      spacing: root.theme.space(12)
      Rectangle {
        width: parent.width
        height: quickColumn.implicitHeight + root.theme.space(28)
        radius: root.theme.radius
        color: root.theme.sunken
        border.width: root.theme.borderWidth
        border.color: root.theme.accent
        Column {
          id: quickColumn
          anchors.centerIn: parent
          width: parent.width - root.theme.space(28)
          spacing: root.theme.space(8)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.code !== "" ? root.code.split("").join(" ") : "…"
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.display * 1.4
            font.bold: true
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "In Jellyfin on your phone or in a browser where you are signed in, open your profile → Quick Connect and enter this code. Omafin signs in as soon as you approve it."
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
            lineHeight: 1.2
          }
        }
      }
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.theme.space(8)
        TextButton {
          theme: root.theme
          text: "Use a password instead"
          onClicked: {
            poll.stop()
            root.code = ""
            root.service.call("auth.quickConnectCancel", {}, function() {})
            root.mode = "password"
            Qt.callLater(function() { if (root) user.forceActiveFocus() })
          }
        }
        TextButton { theme: root.theme; text: "New code"; onClicked: root.startQuickConnect() }
      }
    }

    // Step two, a password.
    Column {
      visible: !!root.server && root.mode === "password"
      width: parent.width
      spacing: root.theme.space(10)
      Flow {
        width: parent.width
        spacing: root.theme.space(6)
        visible: !!root.server && root.server.users.length > 0
        Repeater {
          model: root.server ? root.server.users : []
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: modelData
            icon: "person"
            fontSize: root.theme.small
            selected: user.text === modelData
            onClicked: { user.text = modelData; password.forceActiveFocus() }
          }
        }
      }
      Text { text: "User name"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField {
        id: user
        width: parent.width
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        onAccepted: password.forceActiveFocus()
      }
      Text { text: "Password"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField {
        id: password
        width: parent.width
        echoMode: TextInput.Password
        placeholderText: "Leave empty if your account has none"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        onAccepted: root.signIn()
      }
      Row {
        anchors.right: parent.right
        spacing: root.theme.space(8)
        TextButton {
          visible: !!root.server && root.server.quickConnect
          theme: root.theme
          text: "Use Quick Connect"
          onClicked: { root.mode = "quick"; root.startQuickConnect() }
        }
        TextButton { theme: root.theme; text: "Sign in"; primary: true; busy: root.busy; onClicked: root.signIn() }
      }
    }

    Text {
      visible: root.error !== ""
      width: parent.width
      wrapMode: Text.Wrap
      text: root.error
      textFormat: Text.PlainText
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      visible: !!root.server
      theme: root.theme
      text: "Another server"
      fontSize: root.theme.small
      onClicked: {
        poll.stop()
        if (root.code !== "") root.service.call("auth.quickConnectCancel", {}, function() {})
        root.code = ""
        root.server = null
        root.error = ""
      }
    }
  }
}
