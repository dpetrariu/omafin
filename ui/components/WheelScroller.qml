import QtQuick

// Fast, direct wheel scrolling for a Flickable. Qt's own moves about three
// lines per notch, and a sideways row inside a page turns vertical wheel
// turns into sideways scrolling, so pages crawl. This sits over the
// Flickable and takes the wheel itself: a notch moves `notch` pixels, a
// touchpad moves by what the fingers moved. Sideways input (a horizontal
// swipe, or Shift with the wheel) goes to `sideways(dx, y)` when set.
// It takes no clicks and no hover, so everything under it works as before.
MouseArea {
  id: root

  property Flickable flickable: null
  property real notch: 220
  property var sideways: null

  // Before every wheel step, for a page that animates its keyboard moves.
  signal scrolled()

  anchors.fill: flickable
  acceptedButtons: Qt.NoButton
  hoverEnabled: false
  z: 1000

  function scrollBy(dy) {
    var f = flickable
    if (!f || dy === 0) return
    var top = f.originY - f.topMargin
    var bottom = Math.max(top, f.originY + f.contentHeight + f.bottomMargin - f.height)
    f.cancelFlick()
    f.contentY = Math.max(top, Math.min(bottom, f.contentY + dy))
  }

  onWheel: function(wheel) {
    handle(wheel.angleDelta.x, wheel.angleDelta.y, wheel.pixelDelta.x, wheel.pixelDelta.y,
      (wheel.modifiers & Qt.ShiftModifier) !== 0, wheel.y)
    wheel.accepted = true
  }

  // One wheel event, by its parts, so the UI tests can send one too.
  // Spinning the wheel quickly goes further each notch, up to three times.
  property real speed: 1
  property double lastWheel: 0

  function handle(angleX, angleY, pixelX, pixelY, shift, y) {
    // First, so a page turns off its keyboard glide before the move.
    scrolled()
    var now = Date.now()
    speed = now - lastWheel < 140 ? Math.min(3, speed * 1.35) : 1
    lastWheel = now
    var touchpad = pixelX !== 0 || pixelY !== 0
    var dx = touchpad ? pixelX * 2 : angleX / 120 * notch * speed
    var dy = touchpad ? pixelY * 2.5 : angleY / 120 * notch * speed
    if (shift) {
      // Shift turns the wheel sideways, as in every browser.
      dx = dx !== 0 ? dx : dy
      dy = 0
    }
    if (Math.abs(dx) > Math.abs(dy)) {
      if (typeof sideways === "function") sideways(-dx, y)
    } else {
      scrollBy(-dy)
    }
  }
}
