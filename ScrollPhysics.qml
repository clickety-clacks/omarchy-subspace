import QtQuick

// Scrolling physics for one Flickable.
//
// The momentum model is lifted, with its reasoning intact, from Omarchy Ask
// (github.com/clickety-clacks/omarchy-ask, MIT). Two ideas do that work:
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
//     directly instead — distance derives from deceleration, while the
//     presentation duration is stretched enough to make the tail read.
//
// Added here: the ends of the surface give. Because every path above writes
// contentY directly, Flickable's own bounds behaviour never sees these
// gestures, and an edge would otherwise stop dead. Motion past an edge is
// tracked in an undamped `rawY` and shown through `rubber()`, so pushing
// harder buys progressively less; when the push stops, the surface springs
// back to the edge.
Item {
  id: physics

  required property Flickable surface
  // Tunables. The defaults are Ask's shipped feel.
  property real lineImpulse: 335
  property real pageImpulse: lineImpulse * (740 / 360)
  property real deceleration: 608
  property real step: 44
  // How far the surface can be pulled past an edge, no matter how hard.
  property real maxOvershoot: 92

  readonly property bool coasting: keyboardCoast.running || trackpadCoast.running
    || bounce.running || nudge.running
  property real keyboardVelocityY: 0
  property double keyboardSampleTime: 0
  // The undamped position. Equal to contentY inside the bounds; beyond them it
  // keeps counting while contentY only creeps towards maxOvershoot.
  property real rawY: 0

  signal userScrolled()

  function maxY() {
    if (!surface) return 0
    return Math.max(0, surface.contentHeight - surface.height)
  }

  function scrollable() {
    return surface && surface.contentHeight > surface.height + 1
  }

  function syncRaw() { if (surface) physics.rawY = surface.contentY }

  // Distance currently past an edge: negative above the top, positive below
  // the bottom, zero inside.
  function overshoot() {
    if (!surface) return 0
    var limit = maxY()
    if (surface.contentY < -0.5) return surface.contentY
    if (surface.contentY > limit + 0.5) return surface.contentY - limit
    return 0
  }

  // Asymptotic give: the first pixels past the edge move nearly one for one,
  // and no amount of push reaches past maxOvershoot.
  function damp(distance) {
    var give = Math.max(1, physics.maxOvershoot)
    return give * (1 - Math.exp(-distance / give))
  }

  function rubber(raw) {
    var limit = maxY()
    if (raw < 0) return -physics.damp(-raw)
    if (raw > limit) return limit + physics.damp(raw - limit)
    return raw
  }

  function driveTo(raw) {
    if (!surface) return
    physics.rawY = raw
    surface.contentY = physics.rubber(raw)
  }

  // Spring back to the nearest edge. Returns false when there was nothing to
  // settle, so callers can fall through to their normal behaviour.
  function settleToBounds() {
    if (!surface || physics.overshoot() === 0) return false
    bounce.stop()
    bounce.from = surface.contentY
    bounce.to = surface.contentY < 0 ? 0 : maxY()
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
    physics.syncRaw()
  }

  function jumpToEnd() {
    stopAll()
    if (surface) surface.contentY = maxY()
    physics.syncRaw()
  }

  function glideToEnd() {
    if (!surface) return
    var target = maxY()
    if (Math.abs(target - surface.contentY) < 1) { surface.contentY = target; physics.syncRaw(); return }
    stopAll()
    verticalScroll.from = surface.contentY
    verticalScroll.to = target
    verticalScroll.start()
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

  function scrollLine(direction) { scrollBy(direction * step) }

  // A click-wheel notch at the very end has nowhere to go. Give it the same
  // small give-and-return the trackpad gets, so the edge reads as an edge
  // rather than as a dead input.
  function nudgeEdge(direction) {
    if (!physics.scrollable()) return
    var limit = maxY()
    if (direction < 0 && surface.contentY > 0.5) return
    if (direction > 0 && surface.contentY < limit - 0.5) return
    nudge.home = surface.contentY
    nudge.peak = surface.contentY + direction * Math.min(physics.maxOvershoot * 0.4, 30)
    nudge.restart()
  }

  function keyImpulse(direction, page) {
    if (!surface || direction === 0) return
    verticalScroll.stop()
    surface.cancelFlick()
    trackpadCoast.stop()
    bounce.stop()
    nudge.stop()
    if (!keyboardCoast.running) physics.syncRaw()
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
    var destination = raw
    var pastEdge = false
    if (raw < 0) { destination = -physics.damp(-raw); pastEdge = true }
    else if (raw > limit) { destination = limit + physics.damp(raw - limit); pastEdge = true }
    if (Math.abs(destination - surface.contentY) <= 1) return
    trackpadCoast.from = surface.contentY
    trackpadCoast.to = destination
    // Preserve the sampled trackpad stopping distance while stretching its
    // presentation enough for the final loss of momentum to remain legible.
    var duration = Math.max(900, Math.min(2800,
      Math.round(speed * 1800 / surface.flickDeceleration)))
    // A coast that ends past an edge covers far less ground than it asked for,
    // so it must not spend the full distance's worth of time getting there.
    trackpadCoast.duration = pastEdge
      ? Math.max(180, Math.min(460, Math.round(duration * 0.22)))
      : duration
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
      physics.syncRaw()
    }
    if (wheel.phase === Qt.ScrollEnd) { releaseWheel(); return }

    var elapsed = firstSample ? 16 : Math.max(1, Math.min(80, now - wheelState.lastSampleTime))
    var dy = wheel.pixelDelta.y
    wheelState.releaseVelocityY = wheelState.releaseVelocityY * 0.55 + dy * 1000 / elapsed * 0.45
    wheelState.lastSampleTime = now

    physics.driveTo(physics.rawY - dy)
    physics.userScrolled()
    coastTimer.restart()
  }

  function releaseWheel() {
    coastTimer.stop()
    var velocity = -wheelState.releaseVelocityY
    wheelState.lastSampleTime = 0
    wheelState.releaseVelocityY = 0
    // Let go while past an edge and the edge wins; there is nothing to coast
    // towards out there.
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
      physics.driveTo(physics.rawY + velocity * elapsed)

      // Past the edge the push dies quickly, and what is left of it becomes the
      // spring back rather than more travel.
      var loss = physics.deceleration * elapsed * (physics.overshoot() === 0 ? 1 : 9)
      if (Math.abs(velocity) <= loss) {
        physics.keyboardVelocityY = 0
        stop()
        if (!physics.settleToBounds()) physics.syncRaw()
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
    onFinished: physics.syncRaw()
  }

  NumberAnimation {
    id: trackpadCoast
    target: physics.surface
    property: "contentY"
    easing.type: Easing.OutQuint
    onFinished: if (!physics.settleToBounds()) physics.syncRaw()
  }

  NumberAnimation {
    id: bounce
    target: physics.surface
    property: "contentY"
    duration: 340
    easing.type: Easing.OutCubic
    onFinished: physics.syncRaw()
  }

  SequentialAnimation {
    id: nudge
    property real peak: 0
    property real home: 0
    NumberAnimation {
      target: physics.surface
      property: "contentY"
      to: nudge.peak
      duration: 110
      easing.type: Easing.OutQuad
    }
    NumberAnimation {
      target: physics.surface
      property: "contentY"
      to: nudge.home
      duration: 280
      easing.type: Easing.OutCubic
    }
    onFinished: physics.syncRaw()
  }
}
