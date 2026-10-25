import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"
import "lib/Icons.js" as Icons

// One icon and one click. A dot says mpv is playing something Omafin
// started; the icon turns the urgent colour when the server cannot be
// reached. The tooltip says which.
BarWidget {
  id: root

  moduleName: "omafin"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("omafin") : null
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground

  function pushSettings() {
    if (service && typeof service.applySettings === "function") service.applySettings(settings)
  }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  function openWindow(payload) {
    if (!bar || !bar.shell) return
    var text = JSON.stringify(payload || {})
    if (payload && typeof bar.shell.summon === "function") bar.shell.summon("omafin", text)
    else if (typeof bar.shell.toggle === "function") bar.shell.toggle("omafin", text)
  }

  readonly property bool drawsIcon: !service || service.showBarIcon
  visible: drawsIcon
  implicitWidth: drawsIcon ? button.implicitWidth : 0
  implicitHeight: drawsIcon ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (!root.service) return "Omafin"
      if (!root.service.ready) return "Omafin — starting"
      if (!root.service.configured) return "Omafin — sign in to your Jellyfin server"
      if (root.service.serverError) return "Omafin — " + root.service.serverError
      return "Omafin — " + (root.service.serverName || "Jellyfin")
    }

    readonly property bool busy: !!root.service && root.service.externalPlayback !== null
    readonly property bool attention: !!root.service && root.service.configured && root.service.serverError !== ""

    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: Icons.glyph("logo")
          font.family: Style.font.family
          font.pixelSize: Style.bar.iconFont
          color: button.attention ? Commons.Color.urgent : root.foreground
        }
        Rectangle {
          visible: button.busy
          width: Style.space(5)
          height: width
          radius: width / 2
          color: Commons.Color.accent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(1)
        }
      }
    }

    onPressed: function(buttonCode) {
      root.openWindow(null)
    }
  }

  Rectangle {
    readonly property bool vertical: !!root.bar && root.bar.vertical
    visible: !!root.service && root.service.windowOpen
    color: Commons.Color.accent
    radius: Math.min(width, height) / 2
    width: vertical ? Style.space(2) : Style.space(10)
    height: vertical ? Style.space(10) : Style.space(2)
    x: vertical ? (root.bar.position === "left" ? root.width - width - Style.space(2) : Style.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top" ? root.height - height - Style.space(2) : Style.space(2))
  }
}
