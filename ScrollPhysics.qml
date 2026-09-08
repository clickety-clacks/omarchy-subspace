import QtQuick

// Scrolling physics for one Flickable.
//
// Lifted, with its reasoning intact, from Omarchy Ask
// (github.com/clickety-clacks/omarchy-ask, MIT). Two ideas do the work:
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
Item {
  id: physics

  required property Flickable surface
  // Tunables. The defaults are Ask's shipped feel.
  property real lineImpulse: 335
  property real pageImpulse: lineImpulse * (740 / 360)
  property real deceleration: 608
  property real step: 44

  readonly property bool coasting: keyboardCoast.running || trackpadCoast.running
  property real keyboardVelocityY: 0
  property double keyboardSampleTime: 0
  // Raised while the physics itself moves the viewport, so a tail-follower can
  // tell its own scrolling apart from the reader's.
  property bool driving: false

  signal userScrolled()

  function stopAll() {
    keyboardVelocityY = 0
    keyboardCoast.stop()
    trackpadCoast.stop()
    verticalScroll.stop()
    if (surface) surface.cancelFlick()
  }

  function maxY() {
    if (!surface) return 0
    return Math.max(0, surface.contentHeight - surface.height)
  }

  function jumpToEnd() {
    stopAll()
    if (surface) surface.contentY = maxY()
  }

  function glideToEnd() {
    if (!surface) return
    var target = maxY()
    if (Math.abs(target - surface.contentY) < 1) { surface.contentY = target; return }
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
    if (next === base) return
    verticalScroll.from = surface.contentY
    verticalScroll.to = next
    verticalScroll.start()
    physics.userScrolled()
  }

  function scrollLine(direction) { scrollBy(direction * step) }

  function keyImpulse(direction, page) {
    if (!surface || direction === 0) return
    verticalScroll.stop()
    surface.cancelFlick()
    trackpadCoast.stop()
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
    var destination = Math.max(0, Math.min(maxY(), surface.contentY + direction * distance))
    if (Math.abs(destination - surface.contentY) <= 1) return
    trackpadCoast.from = surface.contentY
    trackpadCoast.to = destination
    // Preserve the sampled trackpad stopping distance while stretching its
    // presentation enough for the final loss of momentum to remain legible.
    trackpadCoast.duration = Math.max(900, Math.min(2800,
      Math.round(speed * 1800 / surface.flickDeceleration)))
    trackpadCoast.start()
  }

  // A coast aimed past a boundary must not sit there animating into the wall.
  function stopCoastAtBoundary() {
    if (!trackpadCoast.running || !surface) return
    var top = surface.originY
    var bottom = Math.max(top, top + surface.contentHeight - surface.height)
    if (trackpadCoast.to <= top && surface.contentY <= top + 0.75) {
      trackpadCoast.stop()
      surface.contentY = top
    } else if (trackpadCoast.to >= bottom && surface.contentY >= bottom - 0.75) {
      trackpadCoast.stop()
      surface.contentY = bottom
    }
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

    physics.driving = true
    surface.contentY = Math.max(0, Math.min(maxY(), surface.contentY - dy))
    physics.driving = false
    physics.userScrolled()
    coastTimer.restart()
  }

  function releaseWheel() {
    coastTimer.stop()
    physics.coastVertically(-wheelState.releaseVelocityY)
    wheelState.lastSampleTime = 0
    wheelState.releaseVelocityY = 0
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
      var limit = physics.maxY()
      var nextY = Math.max(0, Math.min(limit, physics.surface.contentY + velocity * elapsed))
      physics.driving = true
      physics.surface.contentY = nextY
      physics.driving = false

      if ((nextY <= 0 && velocity < 0) || (nextY >= limit && velocity > 0)) {
        physics.keyboardVelocityY = 0
        stop()
        return
      }

      var loss = physics.deceleration * elapsed
      if (Math.abs(velocity) <= loss) {
        physics.keyboardVelocityY = 0
        stop()
      } else {
        physics.keyboardVelocityY = velocity > 0 ? velocity - loss : velocity + loss
      }
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
    target: physics.surface
    property: "contentY"
    easing.type: Easing.OutQuint
  }
}
