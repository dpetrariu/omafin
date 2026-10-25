import QtQuick
import qs.Commons
import qs.Commons as Commons

// The semantic colours and measures every view draws with, derived from the
// active Omarchy theme in one place. App.qml owns the only instance and hands
// it to each component, so nothing picks its own colours.
QtObject {
  readonly property color foreground: Commons.Color.foreground
  readonly property color background: Commons.Color.background
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  // Secondary text mixes foreground toward background rather than darkening.
  readonly property color dim: mix(foreground, background, 0.42)
  readonly property color faint: mix(foreground, background, 0.7)
  readonly property color raised: mix(background, foreground, 0.05)
  readonly property color sunken: mix(background, foreground, 0.025)
  readonly property color border: Style.normalBorderColor
  readonly property int borderWidth: Style.normalBorderWidth
  readonly property color popupBackground: Commons.Color.popups.background
  readonly property color popupBorder: Commons.Color.popups.border
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent, urgent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, accent, urgent)
  readonly property color pressedFill: Style.pressedFillFor(foreground, accent, urgent)
  readonly property color accentFill: Style.selectedAccentFill
  readonly property string font: Style.font.family
  readonly property int radius: Style.cornerRadius
  readonly property int caption: Style.font.caption
  readonly property int small: Style.font.bodySmall
  readonly property int body: Style.font.body
  readonly property int subtitle: Style.font.subtitle
  readonly property int title: Style.font.title
  readonly property int heading: Style.font.heading
  readonly property int display: Style.font.display
  readonly property int icon: Style.font.icon

  function space(px) { return Style.space(px) }

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }

  function alpha(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }
}
