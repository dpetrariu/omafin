import QtQuick
import QtQuick.Window

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
  readonly property bool active: fingersDown || frame.running
  property bool fingersDown: false
  property bool coasting: false
  property real velocity: 0          // px/s, positive scrolls down
  // Where the fingers or the glide say the page should be.
  property real target: 0
  // Where the page really is, to the fraction of a pixel. It follows
  // `target` within about a frame, so touchpad events that arrive unevenly
  // (two in one frame, none in the next) still move the page evenly. The
  // Flickable is only put on whole screen pixels.
  property real exact: 0
  // How quickly the page catches up with the fingers, in seconds.
  readonly property real follow: 0.012
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

  function clamp(y) {
    var b = bounds()
    return Math.max(b.top, Math.min(b.bottom, y))
  }

  function snap(y) {
    var dpr = Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
    return Math.round(y * dpr) / dpr
  }

  // Something else moved the page (a key, a new page of items, a drag):
  // carry on from where it is.
  function sync() {
    var f = flickable
    if (!f) return
    if (!frame.running) {
      exact = target = f.contentY
      return
    }
    if (Math.abs(f.contentY - snap(exact)) > 0.01) {
      var shift = f.contentY - exact
      exact = f.contentY
      target = clamp(target + shift)
    }
  }

  // Move by dy at once, for sideways-free direct moves.
  function scrollBy(dy) {
    stop()
    if (!flickable) return
    flickable.cancelFlick()
    sync()
    target = exact = clamp(exact + dy)
    flickable.contentY = snap(exact)
  }

  // Keyboard moves, drags and new pages call this: the glide gives way,
  // and the page stays where it is now.
  function stop() {
    coasting = false
    velocity = 0
    frame.running = false
    target = exact
  }

  // Every frame: a glide moves the target on and slows down; the page
  // eases toward the target.
  FrameAnimation {
    id: frame
    running: false
    onTriggered: {
      var f = root.flickable
      if (!f) { running = false; return }
      if (Math.abs(f.contentY - root.snap(root.exact)) > 0.01) {
        // Moved under us (a key, a drag): give way.
        root.exact = root.target = f.contentY
        root.coasting = false
        root.velocity = 0
      }
      var dt = Math.min(0.05, frameTime)
      if (root.coasting) {
        var next = root.target + root.velocity * dt
        var held = root.clamp(next)
        root.target = held
        root.velocity *= Math.exp(-dt / root.glide)
        if (held !== next || Math.abs(root.velocity) < 15) { root.coasting = false; root.velocity = 0 }
      }
      root.target = root.clamp(root.target)
      var gap = root.target - root.exact
      root.exact = Math.abs(gap) < 0.25 ? root.target : root.exact + gap * (1 - Math.exp(-dt / root.follow))
      f.contentY = root.snap(root.exact)
      if (!root.coasting && !root.fingersDown && root.exact === root.target) running = false
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
    // Touching catches a glide where it is.
    coasting = false
    velocity = 0
    sync()
    target = exact
    fingersDown = true
    lastEvent = now
    frame.running = true
  }

  function release(now) {
    fingersDown = false
    // Fingers that stopped before lifting leave nothing to coast on.
    if (now - lastEvent > 80) velocity = 0
    coasting = Math.abs(velocity) > 40
    frame.running = true
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
      target = clamp(target + move)
      frame.running = true
      var dt = Math.max(0.004, (now - lastEvent) / 1000)
      lastEvent = now
      var instant = Math.max(-maxSpeed, Math.min(maxSpeed, move / dt))
      // The last few events count most: that is the speed of the release.
      velocity = velocity === 0 ? instant : velocity * 0.4 + instant * 0.6
      return
    }
    // A wheel notch: speed for a glide of about `notch` pixels, added to a
    // glide already going the same way.
    if (!frame.running) sync()
    var push = -dy / glide
    if (velocity !== 0 && (velocity > 0) !== (push > 0)) velocity = 0
    velocity = Math.max(-maxSpeed, Math.min(maxSpeed, velocity + push))
    lastEvent = now
    coasting = true
    frame.running = true
  }
}
