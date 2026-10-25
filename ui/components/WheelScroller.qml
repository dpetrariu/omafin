import QtQuick

// Scrolling with momentum, as on a Mac, for a Flickable. Qt's own wheel
// handling moves a few lines per event and stops dead, and a sideways row
// inside a page turns vertical wheel turns into sideways scrolling, so this
// sits over the Flickable and takes the wheel itself.
//
// - A touchpad: the page follows the fingers while they are down, then
//   coasts from the speed they let go at and slows down smoothly. Touching
//   again catches it. The touchpad reports begin / update / end phases (the
//   VM passes them through; it adds no momentum of its own).
// - A mouse wheel: each notch adds speed rather than jumping, so one notch
//   glides about `notch` pixels and a fast spin builds up and goes far.
// - Sideways input (a horizontal swipe, or Shift with the wheel) goes to
//   `sideways(dx, y)` when set, directly.
//
// It takes no clicks and no hover, so everything under it works as before.
MouseArea {
  id: root

  property Flickable flickable: null
  // How far one wheel notch glides, in pixels.
  property real notch: 220
  property var sideways: null
  // How quickly a glide dies away: the speed falls to a third every `glide`
  // seconds. Longer coasts further.
  property real glide: 0.33
  // Touchpad distance per finger distance while the fingers are down.
  property real fingerGain: 1.25
  readonly property real maxSpeed: 9000

  // True while the fingers move or the page coasts; a page turns off its
  // keyboard glide meanwhile.
  readonly property bool active: fingersDown || coast.running
  property bool fingersDown: false
  property real velocity: 0          // px/s, positive scrolls down
  property double lastEvent: 0

  // Before every wheel step, for a page that animates its keyboard moves.
  signal scrolled()

  anchors.fill: flickable
  acceptedButtons: Qt.NoButton
  hoverEnabled: false
  z: 1000

  function bounds() {
    var f = flickable
    var top = f.originY - f.topMargin
    return { top: top, bottom: Math.max(top, f.originY + f.contentHeight + f.bottomMargin - f.height) }
  }

  // Move by dy now; false when an edge stopped it.
  function moveBy(dy) {
    var f = flickable
    if (!f || dy === 0) return true
    var b = bounds()
    var next = Math.max(b.top, Math.min(b.bottom, f.contentY + dy))
    var free = Math.abs(next - (f.contentY + dy)) < 0.5
    f.contentY = next
    return free
  }

  function scrollBy(dy) {
    stop()
    if (flickable) flickable.cancelFlick()
    moveBy(dy)
  }

  // Keyboard moves, drags and new pages call this: the glide gives way.
  function stop() {
    coast.running = false
    velocity = 0
  }

  // Each frame of a glide: move, then let the speed die away.
  FrameAnimation {
    id: coast
    running: false
    onTriggered: {
      var dt = Math.min(0.05, frameTime)
      if (!root.moveBy(root.velocity * dt)) { root.stop(); return }
      root.velocity *= Math.exp(-dt / root.glide)
      if (Math.abs(root.velocity) < 15) root.stop()
    }
  }

  // A drag with the pointer, or the scrollbar, takes over from a glide.
  Connections {
    target: root.flickable
    function onMovementStarted() { root.stop() }
  }

  onWheel: function(wheel) {
    handle(wheel.angleDelta.x, wheel.angleDelta.y, wheel.pixelDelta.x, wheel.pixelDelta.y,
      (wheel.modifiers & Qt.ShiftModifier) !== 0, wheel.y, wheel.phase)
    wheel.accepted = true
  }

  function begin(now) {
    fingersDown = true
    stop()
    lastEvent = now
  }

  function release(now) {
    fingersDown = false
    // Fingers that stopped before lifting leave nothing to coast on.
    if (now - lastEvent > 80) velocity = 0
    if (Math.abs(velocity) > 40) coast.running = true
  }

  // One wheel event, by its parts, so the UI tests can send one too.
  // `phase` is Qt's: 0 none (a mouse wheel), 1 begin, 2 update, 3 end, 4 momentum.
  // `now` (ms) is for the tests; it defaults to the clock.
  function handle(angleX, angleY, pixelX, pixelY, shift, y, phase, now) {
    scrolled()
    now = now === undefined ? Date.now() : now
    phase = phase || 0
    if (phase === Qt.ScrollBegin) { begin(now); return }
    if (phase === Qt.ScrollEnd) { release(now); return }
    var touchpad = pixelX !== 0 || pixelY !== 0 || phase === Qt.ScrollUpdate || phase === Qt.ScrollMomentum
    var dx = touchpad ? pixelX : angleX / 120 * notch
    var dy = touchpad ? pixelY : angleY / 120 * notch
    if (shift) {
      // Shift turns the wheel sideways, as in every browser.
      dx = dx !== 0 ? dx : dy
      dy = 0
    }
    if (Math.abs(dx) > Math.abs(dy)) {
      if (typeof sideways === "function") sideways(touchpad ? -dx * fingerGain : -dx, y)
      return
    }
    if (touchpad) {
      // Follow the fingers, and remember how fast they went.
      if (!fingersDown && phase !== Qt.ScrollMomentum) begin(now)
      var move = -dy * fingerGain
      if (flickable) flickable.cancelFlick()
      moveBy(move)
      var dt = Math.max(0.004, (now - lastEvent) / 1000)
      lastEvent = now
      var instant = Math.max(-maxSpeed, Math.min(maxSpeed, move / dt))
      // The last few events count most: that is the speed of the release.
      velocity = velocity === 0 ? instant : velocity * 0.4 + instant * 0.6
      return
    }
    // A wheel notch: speed for a glide of about `notch` pixels, added to a
    // glide already going the same way.
    var push = -dy / glide
    if (velocity !== 0 && (velocity > 0) !== (push > 0)) velocity = 0
    velocity = Math.max(-maxSpeed, Math.min(maxSpeed, velocity + push))
    lastEvent = now
    coast.running = true
  }
}
