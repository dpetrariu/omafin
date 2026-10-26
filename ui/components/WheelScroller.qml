import QtQuick

// Scrolling with momentum, as on a Mac, for a Flickable, up and down or
// (`horizontal`) sideways. Qt's own wheel handling moves a few lines per
// event and stops dead, and a sideways row inside a page turns vertical
// wheel turns into sideways scrolling, so this sits over the Flickable and
// takes the wheel itself.
//
// - A touchpad: the content follows the fingers while they are down, then
//   coasts from the speed they let go at and slows down smoothly. Touching
//   again catches it. The touchpad reports begin / update / end phases.
// - A mouse wheel: each notch adds speed rather than jumping, so one notch
//   glides about `notch` pixels and a fast spin builds up and goes far.
// - The ends stretch like a rubber band: a glide carries on a little past
//   the start or end and springs back; fingers pulling past an end meet
//   growing resistance. The end of a page still loading does not stretch.
// - A page with sideways rows (`rowAt(y)` returns the row's own scroller):
//   each touchpad gesture is decided by its first movement. Mostly
//   sideways, the whole gesture goes to the row under the pointer, which
//   follows, coasts and stretches the same way; otherwise the page scrolls.
//   Shift with the wheel, or a sideways wheel, goes to the row too.
//
// It takes no clicks and no hover, so everything under it works as before.
// A row's scroller is fed by its page and takes no wheel itself
// (`takesWheel: false`).
MouseArea {
  id: root

  property Flickable flickable: null
  property bool horizontal: false
  property bool takesWheel: true
  // How far one wheel notch glides, in pixels.
  property real notch: 220
  // For a page: the scroller of the sideways row at this y, or null.
  property var rowAt: null
  // More is still loading below the end: a glide that gets there waits for
  // it (slowing as it would) instead of stopping as if at the bottom.
  property bool moreBelow: false
  // How far the content may sit from this scroller's own position before it
  // counts as moved by something else: the view rounds positions its own
  // way, and a pixel of difference must not end a glide.
  readonly property real slack: 1.5
  // How quickly a glide dies away: the speed falls to a third every `glide`
  // seconds. Longer coasts further.
  property real glide: 0.33
  // Touchpad distance per finger distance while the fingers are down.
  property real fingerGain: 1.25
  readonly property real maxSpeed: 9000

  // True while the fingers move or the content coasts; a page turns off its
  // keyboard glide meanwhile.
  readonly property bool active: fingersDown || frame.running || bouncing
  property bool fingersDown: false
  property bool coasting: false
  property real velocity: 0          // px/s, positive scrolls down (or right)
  // Where the fingers or the glide say the content should be.
  property real target: 0
  // Where the content really is. It follows `target` within about a frame,
  // so touchpad events that arrive unevenly (two in one frame, none in the
  // next) still move it evenly.
  property real exact: 0
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
  // How quickly the content catches up with the fingers, in seconds.
  readonly property real follow: 0.012
  property double lastEvent: 0
  // A page's current touchpad gesture: "" undecided, "own", or "row".
  property string gesture: ""
  property var gestureRow: null
  property double gestureStart: 0

  // Before every wheel step, for a page that animates its keyboard moves.
  signal scrolled()

  anchors.fill: flickable
  acceptedButtons: Qt.NoButton
  hoverEnabled: false
  enabled: takesWheel
  z: 1000

  // ---------------------------------------------------------------- the axis

  function pos() {
    return horizontal ? flickable.contentX : flickable.contentY
  }
  function setPos(v) {
    if (horizontal) flickable.contentX = v
    else flickable.contentY = v
  }
  function bounds() {
    var f = flickable
    if (horizontal) {
      var start = f.originX - f.leftMargin
      return { top: start, bottom: Math.max(start, f.originX + f.contentWidth + f.rightMargin - f.width) }
    }
    var top = f.originY - f.topMargin
    return { top: top, bottom: Math.max(top, f.originY + f.contentHeight + f.bottomMargin - f.height) }
  }

  function clamp(y) {
    var b = bounds()
    return Math.max(b.top, Math.min(b.bottom, y))
  }

  // How far past an end a position is: negative before the start, positive
  // past the end, 0 inside.
  function overscroll(y) {
    var b = bounds()
    return y < b.top ? y - b.top : y > b.bottom ? y - b.bottom : 0
  }

  // How far the content stretches for fingers `over` pixels past an end.
  function rubber(over) {
    var span = flickable ? (horizontal ? flickable.width : flickable.height) : 600
    var d = Math.max(200, span * 0.5)
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

  // Where the content should be kept when its items change underneath: this
  // scroller's own position while it moves, else what the caller saw.
  function position(fallback) {
    return active ? snap(exact) : fallback
  }

  // Something else moved the content (a key, new items, a drag): carry on
  // from where it is.
  function sync() {
    var f = flickable
    if (!f) return
    if (!frame.running) {
      exact = target = fingerRaw = pos()
      return
    }
    if (Math.abs(pos() - snap(exact)) > slack) {
      var shift = pos() - exact
      exact = pos()
      target = clamp(target + shift)
    }
  }

  // Move by dy at once.
  function scrollBy(dy) {
    stop()
    if (!flickable) return
    flickable.cancelFlick()
    sync()
    target = exact = clamp(exact + dy)
    setPos(snap(exact))
  }

  // Glide by about d pixels (the row's arrow buttons).
  function glideBy(d) {
    if (!flickable || d === 0) return
    if (!frame.running) sync()
    if (bouncing) { bouncing = false; exact = target = clamp(exact) }
    velocity = d / glide
    coasting = true
    scrolled()
    frame.running = true
  }

  // Keyboard moves, drags and new pages call this: the glide gives way,
  // and the content stays where it is now.
  function stop() {
    coasting = false
    velocity = 0
    bouncing = false
    bounceVelocity = 0
    frame.running = false
    if (!flickable) return
    // Whatever takes over moves the content itself; never leave it stretched.
    exact = clamp(exact)
    target = fingerRaw = exact
    if (overscroll(pos()) !== 0) setPos(exact)
  }

  // Every frame: a glide moves the target on and slows down, an end
  // springs back, and the content eases toward the target.
  FrameAnimation {
    id: frame
    running: false
    onTriggered: {
      var f = root.flickable
      if (!f) { running = false; return }
      if (!root.bouncing && root.overscroll(root.exact) === 0 && Math.abs(root.pos() - root.snap(root.exact)) > root.slack) {
        // Moved under us (a key, a drag): give way.
        root.exact = root.target = root.fingerRaw = root.pos()
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
        // Let go with the content past an end: spring back.
        root.startBounce(root.clamp(root.exact), 0)
        root.target = root.exact
      } else {
        if (!root.fingersDown) root.target = root.clamp(root.target)
        var gap = root.target - root.exact
        root.exact = Math.abs(gap) < 0.25 ? root.target : root.exact + gap * (1 - Math.exp(-dt / root.follow))
      }
      root.setPos(root.snap(root.exact))
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
    // Fingers that stopped before lifting leave nothing to coast on, and
    // content let go past an end only springs back.
    if (now - lastEvent > 80 || overscroll(target) !== 0) velocity = 0
    coasting = Math.abs(velocity) > 40
    frame.running = true
  }

  // One wheel event, by its parts, so the UI tests (and a page, for its
  // rows) can send one too. `phase` is Qt's: 0 none (a mouse wheel), 1 begin,
  // 2 update, 3 end, 4 momentum. `now` (ms) defaults to the clock.
  function handle(angleX, angleY, pixelX, pixelY, shift, y, phase, now) {
    scrolled()
    now = now === undefined ? Date.now() : now
    phase = phase || 0
    var rows = typeof rowAt === "function"

    if (phase === Qt.ScrollBegin) {
      // Undecided until the fingers move.
      gesture = ""
      gestureRow = null
      gestureStart = now
      begin(now)
      return
    }
    if (phase === Qt.ScrollEnd) {
      if (gesture === "row" && gestureRow) {
        gestureRow.handle(0, 0, 0, 0, false, y, Qt.ScrollEnd, now)
        // The page's own fingers did not move.
        velocity = 0
      }
      gesture = ""
      gestureRow = null
      release(now)
      return
    }

    var touchpad = pixelX !== 0 || pixelY !== 0 || phase === Qt.ScrollUpdate || phase === Qt.ScrollMomentum
    var dx = touchpad ? pixelX : angleX / 120 * notch
    var dy = touchpad ? pixelY : angleY / 120 * notch
    if (shift) {
      // Shift turns the wheel sideways, as in every browser.
      dx = dx !== 0 ? dx : dy
      dy = 0
    }
    var along = horizontal ? dx : dy
    var across = horizontal ? dy : dx

    // A page hands sideways input to the row under the pointer.
    if (rows && !horizontal) {
      if (phase === Qt.ScrollUpdate && gesture === "") {
        if (dx === 0 && dy === 0) return
        var row = Math.abs(dx) > Math.abs(dy) ? rowAt(y) : null
        if (row) {
          gesture = "row"
          gestureRow = row
          row.handle(0, 0, 0, 0, false, y, Qt.ScrollBegin, gestureStart)
        } else {
          gesture = "own"
        }
      }
      if (gesture === "row" && gestureRow) {
        gestureRow.handle(angleX, angleY, pixelX, pixelY, false, y, phase, now)
        return
      }
      if (!touchpad && Math.abs(across) > Math.abs(along)) {
        var wheelRow = rowAt(y)
        if (wheelRow) wheelRow.handle(angleX, angleY, 0, 0, shift, y, 0, now)
        return
      }
    }
    if (touchpad) {
      // Follow the fingers, and remember how fast they went.
      if (!fingersDown && phase !== Qt.ScrollMomentum) begin(now)
      var move = -along * fingerGain
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
    // glide already going the same way. Sideways notches on a scroller that
    // does not go sideways do nothing.
    if (along === 0 || Math.abs(across) > Math.abs(along)) return
    if (!frame.running) sync()
    if (bouncing) { bouncing = false; exact = target = clamp(exact) }
    var push = -along / glide
    if (velocity !== 0 && (velocity > 0) !== (push > 0)) velocity = 0
    velocity = Math.max(-maxSpeed, Math.min(maxSpeed, velocity + push))
    lastEvent = now
    coasting = true
    frame.running = true
  }
}
