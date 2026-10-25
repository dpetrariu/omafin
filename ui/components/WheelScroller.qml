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
// - The ends stretch like a rubber band: a glide carries on a little past
//   the top or bottom and springs back; fingers pulling past an end meet
//   growing resistance. The end of a page still loading does not stretch.
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
  // More is still loading below the end: a glide that gets there waits for
  // it (slowing as it would) instead of stopping as if at the bottom.
  property bool moreBelow: false
  // How far the page may sit from this scroller's own position before it
  // counts as moved by something else: the view rounds positions its own
  // way, and a pixel of difference must not end a glide.
  readonly property real slack: 1.5
  // How quickly a glide dies away: the speed falls to a third every `glide`
  // seconds. Longer coasts further.
  property real glide: 0.33
  // Touchpad distance per finger distance while the fingers are down.
  property real fingerGain: 1.25
  readonly property real maxSpeed: 9000

  // True while the fingers move or the page coasts; a page turns off its
  // keyboard glide meanwhile.
  readonly property bool active: fingersDown || frame.running || bouncing
  property bool fingersDown: false
  property bool coasting: false
  property real velocity: 0          // px/s, positive scrolls down
  // Where the fingers or the glide say the page should be.
  property real target: 0
  // Where the page really is. It follows `target` within about a frame, so
  // touchpad events that arrive unevenly (two in one frame, none in the
  // next) still move the page evenly.
  property real exact: 0
  // The ends stretch like a rubber band: a glide carries a little past the
  // top or bottom and springs back, and fingers pulling past an end meet
  // more resistance the further they go.
  property bool bouncing: false
  property real bounceVelocity: 0
  property real edge: 0
  // The fingers' own position, before the rubber band's resistance.
  property real fingerRaw: 0
  // A damped spring, critically damped so it never wobbles; settles in
  // about a third of a second.
  readonly property real spring: 170
  readonly property real damping: 2 * Math.sqrt(spring)
  readonly property real maxBounceSpeed: 3500
  // The furthest the last bounce stretched, for the tests.
  property real peakStretch: 0
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

  // How far past an end a position is: negative above the top, positive
  // below the bottom, 0 inside.
  function overscroll(y) {
    var b = bounds()
    return y < b.top ? y - b.top : y > b.bottom ? y - b.bottom : 0
  }

  // How far the page stretches for fingers `over` pixels past an end.
  function rubber(over) {
    var d = Math.max(200, (flickable ? flickable.height : 600) * 0.5)
    return (1 - 1 / (over * 0.55 / d + 1)) * d
  }

  function startBounce(at, speed) {
    edge = at
    bouncing = true
    coasting = false
    velocity = 0
    bounceVelocity = Math.max(-maxBounceSpeed, Math.min(maxBounceSpeed, speed))
    peakStretch = 0
    frame.running = true
  }

  // Positions stay fractional: snapping them to whole pixels made the end
  // of a glide move in uneven 0- and 1-pixel steps.
  function snap(y) {
    return y
  }

  // Where the page should be kept when its items change underneath: this
  // scroller's own position while it moves, else what the caller saw.
  function position(fallback) {
    return active ? snap(exact) : fallback
  }

  // Something else moved the page (a key, a new page of items, a drag):
  // carry on from where it is.
  function sync() {
    var f = flickable
    if (!f) return
    if (!frame.running) {
      exact = target = fingerRaw = f.contentY
      return
    }
    if (Math.abs(f.contentY - snap(exact)) > slack) {
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
    bouncing = false
    bounceVelocity = 0
    frame.running = false
    // Whatever takes over moves the page itself; never leave it stretched.
    exact = clamp(exact)
    target = fingerRaw = exact
    if (flickable && overscroll(flickable.contentY) !== 0) flickable.contentY = exact
  }

  // Every frame: a glide moves the target on and slows down, an end
  // springs back, and the page eases toward the target.
  FrameAnimation {
    id: frame
    running: false
    onTriggered: {
      var f = root.flickable
      if (!f) { running = false; return }
      if (!root.bouncing && root.overscroll(root.exact) === 0 && Math.abs(f.contentY - root.snap(root.exact)) > root.slack) {
        // Moved under us (a key, a drag): give way.
        root.exact = root.target = root.fingerRaw = f.contentY
        root.coasting = false
        root.velocity = 0
      }
      // The reported time between frames swings by a few milliseconds while
      // the screen shows them evenly; moving by it makes uneven steps. So
      // step by the averaged frame time, unless a frame really was late.
      var steady = smoothFrameTime > 0.008 ? smoothFrameTime : 1 / 60
      var dt = Math.min(0.05, frameTime > steady * 1.6 ? frameTime : steady)
      var b = root.bounds()
      if (root.coasting) {
        var next = root.target + root.velocity * dt
        root.velocity *= Math.exp(-dt / root.glide)
        if (next > b.bottom && root.moreBelow && root.velocity > 0) {
          root.target = b.bottom          // more is loading: wait for it
        } else if (next < b.top || next > b.bottom) {
          // An end: carry the speed into the rubber band.
          var at = next < b.top ? b.top : b.bottom
          root.exact = root.target = at
          root.startBounce(at, root.velocity)
        } else {
          root.target = next
        }
        if (root.coasting && Math.abs(root.velocity) < 15) { root.coasting = false; root.velocity = 0 }
      }
      if (root.bouncing) {
        var stretch = root.exact - root.edge
        root.bounceVelocity += (-root.spring * stretch - root.damping * root.bounceVelocity) * dt
        root.exact += root.bounceVelocity * dt
        root.target = root.exact
        root.peakStretch = Math.max(root.peakStretch, Math.abs(root.overscroll(root.exact)))
        if (Math.abs(root.exact - root.edge) < 0.3 && Math.abs(root.bounceVelocity) < 8) {
          root.exact = root.target = root.edge
          root.bouncing = false
        }
      } else if (!root.fingersDown && root.overscroll(root.exact) !== 0) {
        // Let go with the page past an end: spring back.
        root.startBounce(root.clamp(root.exact), 0)
        root.target = root.exact
      } else {
        if (!root.fingersDown) root.target = root.clamp(root.target)
        var gap = root.target - root.exact
        root.exact = Math.abs(gap) < 0.25 ? root.target : root.exact + gap * (1 - Math.exp(-dt / root.follow))
      }
      f.contentY = root.snap(root.exact)
      if (!root.coasting && !root.bouncing && !root.fingersDown && root.exact === root.target) running = false
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
    bouncing = false
    sync()
    target = exact
    // Caught while stretched: carry on from the stretch the fingers would
    // have made.
    var over = overscroll(exact)
    fingerRaw = over === 0 ? exact : clamp(exact) + over / 0.55
    fingersDown = true
    lastEvent = now
    frame.running = true
  }

  function release(now) {
    fingersDown = false
    // Fingers that stopped before lifting leave nothing to coast on, and a
    // page let go past an end only springs back.
    if (now - lastEvent > 80 || overscroll(target) !== 0) velocity = 0
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
      fingerRaw += move
      var over = overscroll(fingerRaw)
      if (over > 0 && moreBelow) {
        fingerRaw = target = bounds().bottom   // more is loading: no stretch
      } else {
        target = over === 0 ? fingerRaw : clamp(fingerRaw) + (over > 0 ? 1 : -1) * rubber(Math.abs(over))
      }
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
    if (bouncing) { bouncing = false; exact = target = clamp(exact) }
    var push = -dy / glide
    if (velocity !== 0 && (velocity > 0) !== (push > 0)) velocity = 0
    velocity = Math.max(-maxSpeed, Math.min(maxSpeed, velocity + push))
    lastEvent = now
    coasting = true
    frame.running = true
  }
}
