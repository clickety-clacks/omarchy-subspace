import QtQuick

// Scrolling physics for one Flickable.
//
// The momentum model is taken from Omarchy Ask (github.com/clickety-clacks/
// omarchy-ask, MIT), with the reasoning intact. Two decisions there are
// load-bearing:
//
//   * Keyboard motion is integrated frame by frame. A NumberAnimation cannot
//     model repeated force impulses: restarting an eased position animation on
//     every auto-repeat discards its time derivative, and inferring velocity
//     from the remaining distance is invalid once the easing curve is not the
//     constant-deceleration curve that inference assumes.
//
//   * A precision-scroll gesture is not a pointer drag, so handing its sampled
//     velocity back to Flickable.flick() is unreliable after cancelFlick(): on
//     some Qt/Wayland paths the synthetic flick is discarded along with the
//     wheel sequence that just ended. The stopping distance is animated
//     directly instead.
//
// Added here: the ends give. Because every path writes contentY directly,
// Flickable's own bounds behaviour never sees these gestures and an edge would
// stop dead.
//
// Overscroll is held as `slack` — signed distance past an edge, before
// damping — and never as an absolute position. That distinction is the whole
// design. A live transcript grows underneath you constantly, so a remembered
// absolute position means the edge you are held against moves out from under
// the gesture, and a spring aimed at a remembered position lands somewhere
// that is no longer the end. Slack is relative to wherever the edge is now, so
// growth is simply re-applied, and the spring animates the slack itself.
Item {
  id: physics

  required property Flickable surface
  // Tunables. The defaults are Ask's shipped feel.
  property real lineImpulse: 335
  property real pageImpulse: lineImpulse * (740 / 360)
  property real deceleration: 608
  property real step: 44
  // How far past an edge the surface can be pulled, however hard you push.
  property real maxOvershoot: 64

  // Signed distance past an edge before damping: negative past the top,
  // positive past the bottom, zero inside. Undamped, but bounded — a trackpad
  // keeps sending momentum events after your fingers lift, and unbounded slack
  // would have to be unwound before scrolling the other way did anything.
  property real slackRaw: 0
  readonly property real slackLimit: Math.max(1, maxOvershoot) * 2.5
  readonly property bool overscrolled: slackRaw !== 0
  readonly property bool coasting: keyboardCoast.running || trackpadCoast.running
    || bounce.running || nudge.running
  // True whenever the physics owns the viewport and nothing else should move it.
  readonly property bool busy: coasting || overscrolled

  property real keyboardVelocityY: 0
  property double keyboardSampleTime: 0

  signal userScrolled()

  function maxY() {
    if (!surface) return 0
    return Math.max(0, surface.contentHeight - surface.height)
  }

  function scrollable() {
    return surface && surface.contentHeight > surface.height + 1
  }

  // Asymptotic give: the first pixels past an edge move nearly one for one,
  // and no amount of push reaches past maxOvershoot.
  function damp(distance) {
    var give = Math.max(1, physics.maxOvershoot)
    return give * (1 - Math.exp(-distance / give))
  }

  // Position is always recomputed from where the edges are now, which is what
  // lets a growing transcript stay put under a held gesture.
  function applySlack() {
    if (!surface) return
    var limit = maxY()
    if (physics.slackRaw < 0) surface.contentY = -physics.damp(-physics.slackRaw)
    else if (physics.slackRaw > 0) surface.contentY = limit + physics.damp(physics.slackRaw)
    else surface.contentY = Math.max(0, Math.min(limit, surface.contentY))
  }

  onSlackRawChanged: physics.applySlack()

  // Content changed shape while a gesture is holding an edge.
  function reanchor() { if (physics.overscrolled) physics.applySlack() }

  function reset() {
    physics.slackRaw = 0
    physics.applySlack()
  }

  // The single path that moves the surface by an amount. Inside the bounds it
  // moves content; past them it moves slack; crossing back through an edge
  // spends the remainder on content again, so reversing direction is immediate.
  function driveBy(delta) {
    if (!surface || delta === 0) return
    var limit = maxY()
    if (physics.slackRaw !== 0) {
      var edge = physics.slackRaw > 0 ? limit : 0
      var next = physics.slackRaw + delta
      if (next !== 0 && (physics.slackRaw > 0) === (next > 0)) {
        var bounded = Math.max(-physics.slackLimit, Math.min(physics.slackLimit, next))
        if (bounded === physics.slackRaw) physics.applySlack()
        else physics.slackRaw = bounded
        return
      }
      physics.slackRaw = 0
      surface.contentY = Math.max(0, Math.min(limit, edge + next))
      return
    }
    var target = surface.contentY + delta
    if (target < 0) { physics.slackRaw = target; return }
    if (target > limit) { physics.slackRaw = target - limit; return }
    surface.contentY = target
  }

  // Spring the slack out. Returns false when there was none, so callers can
  // fall through to their normal behaviour.
  function settleToBounds() {
    if (physics.slackRaw === 0) return false
    nudge.stop()
    bounce.stop()
    bounce.from = physics.slackRaw
    bounce.start()
    return true
  }

  function stopAll() {
    keyboardVelocityY = 0
    keyboardCoast.stop()
    trackpadCoast.stop()
    verticalScroll.stop()
    bounce.stop()
    nudge.stop()
    if (surface) surface.cancelFlick()
    physics.reset()
  }

  // Steps accumulate onto a running animation's destination. Measuring from
  // the animated value instead would swallow most of a held key or a fast
  // wheel spin, because every event would restart from a half-finished move.
  function scrollBy(dy) {
    if (!surface) return
    var base = verticalScroll.running ? verticalScroll.to : surface.contentY
    stopAll()
    var next = Math.max(0, Math.min(maxY(), base + dy))
    if (next === base) { physics.nudgeEdge(dy < 0 ? -1 : 1); return }
    verticalScroll.from = surface.contentY
    verticalScroll.to = next
    verticalScroll.start()
    physics.userScrolled()
  }

  // A click-wheel notch at the very end has nowhere to go. Give it the same
  // give-and-return the trackpad gets, so the end reads as an end rather than
  // as a dead input.
  function nudgeEdge(direction) {
    if (!physics.scrollable()) return
    var limit = maxY()
    if (direction < 0 && surface.contentY > 0.5) return
    if (direction > 0 && surface.contentY < limit - 0.5) return
    physics.spring(direction * Math.min(physics.maxOvershoot * 0.5, 24))
  }

  // Out to a peak of slack and back, for an impact that had nowhere to go.
  function spring(peak) {
    bounce.stop()
    nudge.stop()
    nudge.peak = peak
    nudge.start()
  }

  function keyImpulse(direction, page) {
    if (!surface || direction === 0) return
    verticalScroll.stop()
    surface.cancelFlick()
    trackpadCoast.stop()
    bounce.stop()
    nudge.stop()
    var impulse = page ? physics.pageImpulse : physics.lineImpulse
    keyboardVelocityY = Math.max(-surface.maximumFlickVelocity,
      Math.min(surface.maximumFlickVelocity, keyboardVelocityY + direction * impulse))
    keyboardSampleTime = Date.now()
    keyboardCoast.start()
    physics.userScrolled()
  }

  function coastVertically(velocity) {
    if (!surface) return
    trackpadCoast.stop()
    var speed = Math.min(surface.maximumFlickVelocity, Math.abs(velocity))
    if (speed <= 40) return
    var direction = velocity < 0 ? -1 : 1
    var distance = speed * speed / (2 * surface.flickDeceleration)
    var limit = maxY()
    var raw = surface.contentY + direction * distance
    var destination = Math.max(0, Math.min(limit, raw))
    var travel = Math.abs(destination - surface.contentY)
    var excess = Math.abs(raw - destination)
    if (travel <= 1 && excess <= 1) return
    trackpadCoast.from = surface.contentY
    trackpadCoast.to = destination
    // Preserve the sampled trackpad stopping distance while stretching its
    // presentation enough for the final loss of momentum to remain legible.
    var full = Math.max(900, Math.min(2800,
      Math.round(speed * 1800 / surface.flickDeceleration)))
    // Only the part of the journey that actually happens gets to take time. A
    // coast cut short by an edge must not spend the whole distance's worth of
    // it crawling there.
    trackpadCoast.duration = Math.max(120,
      Math.round(full * (distance > 0 ? Math.min(1, travel / distance) : 0)))
    // Whatever the edge absorbed comes back as the bounce.
    trackpadCoast.spill = excess > 1
      ? direction * Math.min(physics.maxOvershoot * 1.1, excess * 0.35) : 0
    trackpadCoast.start()
  }

  // Qt/Wayland may report a two-finger trackpad stream as either a touchpad or
  // a mouse. Pixel deltas distinguish that stream from a click wheel, whose
  // notches keep using the animated keyboard step.
  function handleWheel(wheel) {
    wheel.accepted = true
    if (!surface) return
    if (wheel.pixelDelta.x === 0 && wheel.pixelDelta.y === 0) {
      var steps = wheel.angleDelta.y / 120
      if (steps !== 0) physics.scrollBy(-steps * 3 * physics.step)
      return
    }

    verticalScroll.stop()
    keyboardVelocityY = 0
    keyboardCoast.stop()
    trackpadCoast.stop()
    bounce.stop()
    nudge.stop()
    surface.cancelFlick()

    var now = Date.now()
    var firstSample = wheel.phase === Qt.ScrollBegin || wheelState.lastSampleTime === 0
    if (firstSample) {
      wheelState.lastSampleTime = now
      wheelState.releaseVelocityY = 0
    }
    if (wheel.phase === Qt.ScrollEnd) { releaseWheel(); return }

    var elapsed = firstSample ? 16 : Math.max(1, Math.min(80, now - wheelState.lastSampleTime))
    var dy = wheel.pixelDelta.y
    wheelState.releaseVelocityY = wheelState.releaseVelocityY * 0.55 + dy * 1000 / elapsed * 0.45
    wheelState.lastSampleTime = now

    physics.driveBy(-dy)
    physics.userScrolled()
    coastTimer.restart()
  }

  function releaseWheel() {
    coastTimer.stop()
    var velocity = -wheelState.releaseVelocityY
    wheelState.lastSampleTime = 0
    wheelState.releaseVelocityY = 0
    // Let go while past an edge and the edge wins; there is nothing out there
    // to coast towards.
    if (physics.settleToBounds()) return
    physics.coastVertically(velocity)
  }

  QtObject {
    id: wheelState
    property double lastSampleTime: 0
    property real releaseVelocityY: 0
  }

  Timer {
    id: coastTimer
    interval: 55
    onTriggered: physics.releaseWheel()
  }

  Timer {
    id: keyboardCoast
    interval: 16
    repeat: true
    onTriggered: {
      if (!physics.surface) { stop(); return }
      var now = Date.now()
      var elapsed = Math.max(1, Math.min(40, now - physics.keyboardSampleTime)) / 1000
      physics.keyboardSampleTime = now
      var velocity = physics.keyboardVelocityY
      physics.driveBy(velocity * elapsed)

      // Past the edge the push dies quickly, and what is left of it becomes the
      // spring back rather than more travel.
      var loss = physics.deceleration * elapsed * (physics.overscrolled ? 9 : 1)
      if (Math.abs(velocity) <= loss) {
        physics.keyboardVelocityY = 0
        stop()
        physics.settleToBounds()
        return
      }
      physics.keyboardVelocityY = velocity > 0 ? velocity - loss : velocity + loss
    }
  }

  NumberAnimation {
    id: verticalScroll
    target: physics.surface
    property: "contentY"
    duration: 170
    easing.type: Easing.OutCubic
  }

  NumberAnimation {
    id: trackpadCoast
    property real spill: 0
    target: physics.surface
    property: "contentY"
    easing.type: Easing.OutQuint
    onFinished: {
      var carried = trackpadCoast.spill
      trackpadCoast.spill = 0
      if (carried !== 0) physics.spring(carried)
    }
  }

  // Both springs animate the slack, not the position, so an edge that moves
  // while they run is followed rather than fought.
  NumberAnimation {
    id: bounce
    target: physics
    property: "slackRaw"
    to: 0
    duration: 300
    easing.type: Easing.OutCubic
    onFinished: physics.applySlack()
  }

  SequentialAnimation {
    id: nudge
    property real peak: 0
    NumberAnimation {
      target: physics
      property: "slackRaw"
      to: nudge.peak
      duration: 120
      easing.type: Easing.OutQuad
    }
    NumberAnimation {
      target: physics
      property: "slackRaw"
      to: 0
      duration: 260
      easing.type: Easing.OutCubic
    }
    onFinished: physics.applySlack()
  }
}
