import QtQml
import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import qs.Commons

FloatingWindow {
  id: win

  required property var client

  visible: false
  title: "Subspace Communicator"
  color: Color.background
  implicitWidth: 880
  implicitHeight: 720
  minimumSize: Qt.size(460, 380)

  // ---------------------------------------------------------------- theme
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color rule: Util.alpha(foreground, 0.12)
  readonly property string fontFamily: Style.font.family
  readonly property real fontScale: client.fontScale
  readonly property int captionSize: Math.round(Style.font.caption * fontScale)
  readonly property int bodySize: Math.round(Style.font.body * fontScale)
  readonly property int titleSize: Math.round(Style.font.subtitle * fontScale)
  readonly property int pad: Math.round(Style.spacing.panelPadding * fontScale)

  readonly property color statusColor: {
    if (client.connectionState === "connected") return accent
    if (client.connectionState === "connecting") return muted
    return urgent
  }
  readonly property string statusLabel: {
    if (client.connectionState === "connected") return "connected"
    if (client.connectionState === "connecting") return "connecting"
    if (client.connectionState === "reconnecting") return "reconnecting"
    if (client.connectionState === "unconfigured") return "not configured"
    if (client.connectionState === "fatal") return "unavailable"
    return client.connectionState
  }

  // ----------------------------------------------------------- transcript
  property bool followTail: true
  property string composerError: ""
  readonly property string unreadAnchorId: client.unreadAnchorId

  // FloatingWindow is a Quickshell wrapper, not a QWindow. The standard
  // QtQuick attached property gives us the actual native window, which is the
  // only object that carries `active` and `alert`.
  function nativeWindow() {
    return contentItem && contentItem.Window ? contentItem.Window.window : null
  }

  function isFocused() {
    var native = nativeWindow()
    return win.visible && native !== null && native.active === true
  }

  // Named to stay clear of anything the FloatingWindow wrapper defines.
  function activateWindow() {
    var native = nativeWindow()
    if (native) native.requestActivate()
  }

  function focusComposer() { composer.forceActiveFocus() }

  function messageArrived(space, event) {
    // Replayed history is what was already said before this client attached.
    // It is not news, and it must never raise urgency.
    if (event.replay === true) return
    if (event.own === true) { space.clearUnread(); return }
    // A message in a space you are not looking at counts, and shows on its
    // tab, but only the window's focus decides whether the desktop is told.
    if (space === client.activeLink && win.isFocused()) { space.clearUnread(); return }

    space.noteUnread(event.id)
    if (client.attention) win.raiseAttention()
  }

  function raiseAttention() {
    var native = nativeWindow()
    // A hidden window has no surface for the compositor to mark. The unread
    // count is still kept, so nothing is lost — it is just not shouted about.
    if (!win.visible || !native) return "the window is closed; nothing to mark"
    if (native.active) return "the window already has focus"
    native.alert(0)
    return "urgency requested"
  }

  // The "new" mark outlives the unread count on purpose: the count answers
  // "is there anything?", the mark answers "where did I stop?". It goes away
  // when you have actually caught up, not the moment you glance at the window.
  function clearUnreadMarkIfCaughtUp() {
    var link = client.activeLink
    if (!link || link.unreadAnchorId === "") return
    if (!win.atBottom() || !win.isFocused()) return
    link.unreadAnchorId = ""
  }

  function sendFailed(space, text, detail) {
    if (space !== client.activeLink) return
    win.composerError = detail
    if (composer.text === "") composer.text = text
  }

  function submit() {
    var body = composer.text
    if (body.replace(/\s+/g, "") === "") return
    if (!client.send(body)) {
      win.composerError = client.activeLink === null
        ? "No Subspace configured yet." : "Not connected to Subspace yet."
      return
    }
    win.composerError = ""
    composer.text = ""
    // Snap, do not glide. An animation started here would still be running
    // when the message comes back from the server and the transcript grows,
    // and the two would fight over contentY for the length of the animation.
    // stopAll() first so a gesture still holding an edge does not block the pin.
    physics.stopAll()
    win.followTail = true
    win.keepTail()
  }

  // Following the tail has to happen in the same frame the content grows in.
  // Deferring it by even one frame is visible: the transcript jumps up as the
  // row is added and then slides back down.
  //
  // Every message is laid out, so contentHeight is the real height and the end
  // is simply that minus the viewport. The re-entry guard is because this runs
  // from the contentHeight handler.
  property bool pinning: false
  function keepTail() {
    if (win.pinning || !win.followTail || physics.busy
        || transcript.dragging || transcript.flicking) return
    win.pinning = true
    transcript.contentY = physics.maxY()
    win.pinning = false
  }

  // Put a message's own top at the top of the viewport.
  function positionAtMessage(index) {
    var item = messageRepeater.itemAt(index)
    if (!item) return false
    transcript.contentY = Math.max(0, Math.min(physics.maxY(), item.y))
    return true
  }

  // Within a couple of pixels of the end counts as the end. Asking Flickable's
  // atYEnd instead ties the decision to a fuzzy comparison that a transcript
  // growing every second keeps flipping.
  function atBottom() {
    return transcript.contentY >= physics.maxY() - 2
  }

  function restoreReadingPosition() {
    var link = client.activeLink
    // Carry the message's identity, not its row number. Rows shift when the
    // buffer trims, and the active space can change outright, between
    // scheduling this and running it.
    var anchor = link ? link.unreadAnchorId : ""
    if (link) link.clearUnread()
    Qt.callLater(function() {
      if (link !== client.activeLink) return
      physics.stopAll()
      // Coming back to a backlog should land where you stopped reading, not at
      // the bottom past everything you missed.
      var resume = link ? link.indexOfMessage(anchor) : -1
      win.followTail = resume < 0 || !win.positionAtMessage(resume)
      if (win.followTail) transcript.contentY = physics.maxY()
      win.syncTrimHold()
      composer.forceActiveFocus()
    })
  }

  function spaceSelected() {
    win.composerError = ""
    physics.stopAll()
    win.restoreReadingPosition()
  }

  onVisibleChanged: {
    if (!visible) { client.windowDismissed(); return }
    win.restoreReadingPosition()
  }

  // ------------------------------------------------------- key handling
  // A focused TextEdit claims navigation keys before a window Shortcut can see
  // them, so every text surface routes its keys through here.
  function handleKey(event, inComposer) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

    if (ctrl && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)) {
      client.cycleSpace(shift ? -1 : 1)
      return true
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      win.focusComposer()
      return true
    }
    if (event.key === Qt.Key_Escape) { client.close(); return true }
    if (ctrl && shift && event.key === Qt.Key_A) { client.toggleAttention(); return true }

    if (ctrl && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) {
      client.stepFontScale(0.1); return true
    }
    if (ctrl && (event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore)) {
      client.stepFontScale(-0.1); return true
    }
    if (ctrl && event.key === Qt.Key_0) { client.setFontScale(1); return true }

    if (ctrl && event.key === Qt.Key_K) { win.scrollImpulse(-1, false); return true }
    if (ctrl && event.key === Qt.Key_J) { win.scrollImpulse(1, false); return true }
    if (ctrl && event.key === Qt.Key_U) { win.scrollImpulse(-1, true); return true }
    if (ctrl && event.key === Qt.Key_D) { win.scrollImpulse(1, true); return true }
    if (event.key === Qt.Key_PageUp) { win.scrollImpulse(-1, true); return true }
    if (event.key === Qt.Key_PageDown) { win.scrollImpulse(1, true); return true }

    if (ctrl && event.key === Qt.Key_Home) { win.jumpToStart(); return true }
    if (ctrl && event.key === Qt.Key_End) { win.jumpToLatest(); return true }

    // In the composer the vertical arrows belong to the transcript, because a
    // one-line prompt has nowhere for the caret to go. Once you have started a
    // second line they are caret keys again.
    if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
      if (inComposer && composer.lineCount > 1) return false
      win.scrollImpulse(event.key === Qt.Key_Up ? -1 : 1, false)
      return true
    }
    if (!inComposer) {
      if (event.key === Qt.Key_Home) { win.jumpToStart(); return true }
      if (event.key === Qt.Key_End) { win.jumpToLatest(); return true }
      if (event.key === Qt.Key_Space) { win.scrollImpulse(shift ? -1 : 1, true); return true }
    }
    return false
  }

  // Trimming the buffer is only safe where it cannot be seen: at the tail,
  // where the view is re-pinned to the end anyway. Called on every transition
  // and again after anything that changes which space is on screen, because
  // arriving at the same value of followTail emits no change signal and would
  // leave the new space trimming under a reader.
  function syncTrimHold() {
    var link = client.activeLink
    if (!link) return
    link.holdTrim = !win.followTail
    if (win.followTail) link.trimNow()
  }

  onFollowTailChanged: win.syncTrimHold()

  function scrollImpulse(direction, page) {
    win.followTail = false
    physics.keyImpulse(direction, page)
  }

  function jumpToStart() {
    // stopAll() springs any slack out, which lands on an edge and can re-arm
    // following on the way past. followTail is settled last, after the move.
    physics.stopAll()
    transcript.contentY = 0
    win.followTail = false
  }

  function jumpToLatest() {
    var link = client.activeLink
    win.followTail = true
    if (link) { link.clearUnread(); link.unreadAnchorId = "" }
    physics.stopAll()
    transcript.contentY = physics.maxY()
  }

  // ------------------------------------------------------------- contents
  Item {
    anchors.fill: parent
    focus: true
    Keys.onPressed: function(event) { if (win.handleKey(event, false)) event.accepted = true }

    // Backstop for the case where nothing inside the window holds focus at
    // all. Qt consumes a matched shortcut before the key reaches the focus
    // item, so only bindings that mean the same thing everywhere belong here:
    // the arrows stay out so they can still move the caret in a wrapped draft.
    Shortcut { sequence: "Tab"; onActivated: win.focusComposer() }
    Shortcut { sequence: "Shift+Tab"; onActivated: win.focusComposer() }
    Shortcut { sequence: "Escape"; onActivated: client.close() }
    Shortcut { sequence: "Ctrl+Tab"; onActivated: client.cycleSpace(1) }
    Shortcut { sequence: "Ctrl+Shift+Tab"; onActivated: client.cycleSpace(-1) }
    Shortcut { sequence: "Ctrl+Shift+A"; onActivated: client.toggleAttention() }
    Shortcut { sequence: "Ctrl+J"; onActivated: win.scrollImpulse(1, false) }
    Shortcut { sequence: "Ctrl+K"; onActivated: win.scrollImpulse(-1, false) }
    Shortcut { sequence: "Ctrl+D"; onActivated: win.scrollImpulse(1, true) }
    Shortcut { sequence: "Ctrl+U"; onActivated: win.scrollImpulse(-1, true) }
    Shortcut { sequence: "PageDown"; onActivated: win.scrollImpulse(1, true) }
    Shortcut { sequence: "PageUp"; onActivated: win.scrollImpulse(-1, true) }
    Shortcut { sequence: "Ctrl+End"; onActivated: win.jumpToLatest() }
    Shortcut { sequence: "Ctrl+Home"; onActivated: win.jumpToStart() }
    Shortcut { sequence: "Ctrl+="; onActivated: client.stepFontScale(0.1) }
    Shortcut { sequence: "Ctrl++"; onActivated: client.stepFontScale(0.1) }
    Shortcut { sequence: "Ctrl+-"; onActivated: client.stepFontScale(-0.1) }
    Shortcut { sequence: "Ctrl+0"; onActivated: client.setFontScale(1) }

    Instantiator {
      model: 9
      delegate: Shortcut {
        required property int index
        sequence: "Alt+" + (index + 1)
        onActivated: client.selectSpace(index)
      }
    }

    // -------------------------------------------------------------- header
    Item {
      id: header
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Math.round(Style.space(42) * win.fontScale)

      // A Row lays out left to right and never shrinks, so the left half needs
      // a clip of its own: in a narrow window it would otherwise draw straight
      // through the controls on the right.
      Item {
        id: brandClip
        anchors.left: parent.left
        anchors.leftMargin: win.pad
        anchors.right: headerRight.left
        anchors.rightMargin: Style.spacing.lg
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        clip: true

        Row {
          id: brand
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.lg

          Rectangle {
            width: Math.round(win.captionSize * 0.6)
            height: width
            radius: width / 2
            color: win.statusColor
            anchors.verticalCenter: parent.verticalCenter
            opacity: client.connected ? 1 : 0.75
            SequentialAnimation on opacity {
              running: !client.connected
              loops: Animation.Infinite
              NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 0.9; duration: 900; easing.type: Easing.InOutQuad }
            }
          }

          Text {
            text: "SUBSPACE"
            color: win.foreground
            font.family: win.fontFamily
            font.pixelSize: win.titleSize
            font.letterSpacing: Math.max(1, Math.round(win.titleSize * 0.14))
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
          }

          // One space needs no switcher — it just says where you are.
          Text {
            visible: client.linkList.length < 2
            text: client.activeLink === null
              ? win.statusLabel
              : (client.activeLink.displayName
                 + (client.connected ? "" : " · " + win.statusLabel))
            color: client.connected ? win.muted : win.statusColor
            font.family: win.fontFamily
            font.pixelSize: win.captionSize
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            width: Math.max(0, Math.min(implicitWidth,
              brandClip.width - brand.x - x))
          }

          // More than one, and the header becomes a switcher. Each tab carries
          // its own connection dot and its own unread count, so a quiet space
          // and a broken one do not look the same.
          Row {
            visible: client.linkList.length > 1
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Repeater {
              model: client.linkList

              delegate: Item {
                id: tab
                required property var modelData
                required property int index
                readonly property bool current: client.activeIndex === index

                width: tabRow.implicitWidth + Style.spacing.controlPaddingX * 2
                height: Math.round(Style.spacing.controlHeight * win.fontScale)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
                  color: tab.current ? Style.selectedAccentFill
                    : (tabArea.containsMouse ? Style.hoverFill : "transparent")
                  border.width: 1
                  border.color: tab.current ? Util.alpha(win.accent, 0.55)
                    : (tabArea.containsMouse ? Style.hoverBorderColor : "transparent")
                }

                Row {
                  id: tabRow
                  anchors.centerIn: parent
                  spacing: Style.spacing.sm

                  Rectangle {
                    width: Math.round(win.captionSize * 0.5)
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: tab.modelData.connected ? win.accent : win.urgent
                    opacity: tab.modelData.connected ? 0.9 : 0.7
                  }

                  Text {
                    text: tab.modelData.displayName
                    anchors.verticalCenter: parent.verticalCenter
                    color: tab.current ? win.foreground : win.muted
                    font.family: win.fontFamily
                    font.pixelSize: win.captionSize
                    font.weight: tab.current ? Font.DemiBold : Font.Normal
                  }

                  Text {
                    visible: tab.modelData.unread > 0
                    text: tab.modelData.unread
                    anchors.verticalCenter: parent.verticalCenter
                    color: win.accent
                    font.family: win.fontFamily
                    font.pixelSize: win.captionSize
                    font.weight: Font.DemiBold
                  }
                }

                MouseArea {
                  id: tabArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: client.selectSpace(tab.index)
                }
              }
            }
          }
        }
      }

      Row {
        id: headerRight
        anchors.right: parent.right
        anchors.rightMargin: win.pad
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xl

        Text {
          text: client.resolvedIdentity
          visible: text !== "" && header.width > Style.space(430) * win.fontScale
          color: win.muted
          font.family: win.fontFamily
          font.pixelSize: win.captionSize
          elide: Text.ElideMiddle
          anchors.verticalCenter: parent.verticalCenter
        }

        // The attention switch. Deliberately in the main window rather than a
        // settings page: whether the desktop is allowed to interrupt you is a
        // decision you change in the middle of a conversation, not once.
        Item {
          id: attentionToggle
          width: attentionRow.implicitWidth + Style.spacing.controlPaddingX * 2
          height: Math.round(Style.spacing.controlHeight * win.fontScale)
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
            color: attentionArea.containsMouse ? Style.hoverFill : "transparent"
            border.width: 1
            border.color: attentionArea.containsMouse ? Style.hoverBorderColor : "transparent"
          }

          Row {
            id: attentionRow
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Rectangle {
              id: checkBox
              width: Math.round(win.bodySize * 1.05)
              height: width
              radius: Style.space(3)
              anchors.verticalCenter: parent.verticalCenter
              color: client.attention ? Util.alpha(win.accent, 0.9) : "transparent"
              border.width: 1
              border.color: client.attention ? win.accent : Util.alpha(win.foreground, 0.45)
              Behavior on color { ColorAnimation { duration: 120 } }

              Text {
                anchors.centerIn: parent
                text: "✓"
                visible: client.attention
                color: win.background
                font.family: win.fontFamily
                font.pixelSize: Math.round(checkBox.width * 0.8)
                font.weight: Font.Bold
              }
            }

            Text {
              text: "Alert me"
              anchors.verticalCenter: parent.verticalCenter
              color: client.attention ? win.foreground : win.muted
              font.family: win.fontFamily
              font.pixelSize: win.captionSize
            }
          }

          MouseArea {
            id: attentionArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: client.toggleAttention()
          }
        }
      }
    }

    Rectangle {
      id: headerRule
      anchors.top: header.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 1
      color: win.rule
    }

    // ---------------------------------------------------------- transcript
    //
    // A Flickable holding a Column of every message, not a ListView. The
    // physics here drives contentY directly, and that is only meaningful when
    // contentHeight is measured. A ListView extrapolates contentHeight from
    // the rows it has actually built, so with wrapped text of wildly differing
    // heights its idea of the end is fiction: scrolling lands in estimated
    // void with nothing drawn there, and the scroll indicator points at a
    // position that does not exist. Laying every message out costs memory and
    // startup time, bounded by messageLimit, and buys an exact contentHeight.
    Flickable {
      id: transcript
      anchors.top: headerRule.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: composerRule.top
      anchors.leftMargin: win.pad
      anchors.rightMargin: win.pad
      anchors.topMargin: Style.spacing.lg
      anchors.bottomMargin: Style.spacing.lg
      clip: true
      contentWidth: width
      contentHeight: stack.height
      interactive: contentHeight > height
      // Our own gestures write contentY directly and provide their own give at
      // the edges, so Flickable is told to leave the bounds alone.
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      maximumFlickVelocity: 6000
      flickDeceleration: 650

      onContentYChanged: {
        if (win.atBottom()) {
          win.followTail = true
          win.clearUnreadMarkIfCaughtUp()
        }
      }
      // A gesture holding an edge is re-anchored to where that edge now is;
      // only a settled viewport follows the tail.
      onContentHeightChanged: physics.overscrolled ? physics.reanchor() : win.keepTail()
      onHeightChanged: physics.overscrolled ? physics.reanchor() : win.keepTail()
      // Flickable's own drag and flick move contentY without going through the
      // physics, so they have to say so themselves or the tail pin fights them.
      onDraggingChanged: if (dragging) win.followTail = false
      onFlickStarted: win.followTail = false

      Column {
        id: stack
        width: transcript.width
        spacing: Style.space(6)

        Repeater {
          id: messageRepeater
          model: client.messageModel

          delegate: MessageRow {
            width: stack.width
            host: win
          }
        }
      }

      WheelHandler {
        target: null
        blocking: true
        acceptedButtons: Qt.NoButton
        acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
        onWheel: function(wheel) { physics.handleWheel(wheel) }
      }
    }

    // Kept outside the Flickable on purpose: a Flickable's plain children are
    // parented into the scrolling content item, so anything anchored to
    // "parent" in there quietly scrolls away with the transcript.
    ScrollPhysics {
      id: physics
      surface: transcript
      lineImpulse: client.keyboardLineImpulse
      deceleration: client.keyboardDeceleration
      step: Math.round(Style.space(44) * win.fontScale)
      maxOvershoot: Math.max(36, Math.min(72, Math.round(transcript.height * 0.1)))
      onUserScrolled: win.followTail = false
    }

    // Empty state. A firehose with nothing on it looks identical to a broken
    // client unless the client says which one it is.
    Text {
      anchors.centerIn: transcript
      visible: messageRepeater.count === 0
      width: transcript.width * 0.75
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      color: win.muted
      font.family: win.fontFamily
      font.pixelSize: win.bodySize
      text: client.connected
        ? "Connected. Nothing has been said yet."
        : (client.connectionDetail !== "" ? client.connectionDetail
           : "Reaching Subspace…")
    }

    // A slim presence indicator: enough to show where you are in a long
    // firehose, gone again as soon as you stop moving.
    Rectangle {
      id: scrollIndicator
      x: transcript.x + transcript.width - width
      width: Style.space(3)
      radius: width / 2
      color: Util.alpha(win.foreground, 0.35)
      visible: transcript.contentHeight > transcript.height + 1
      opacity: transcript.moving || physics.coasting || !win.followTail ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 400 } }
      height: Math.max(Style.space(24),
        transcript.height * transcript.height / Math.max(1, transcript.contentHeight))
      y: transcript.y + (transcript.height - height)
        * Math.max(0, Math.min(1, transcript.contentY
          / Math.max(1, transcript.contentHeight - transcript.height)))
    }

    // Jump-to-latest pill. Only there when it has something to say.
    Rectangle {
      id: jumpPill
      anchors.right: transcript.right
      anchors.bottom: transcript.bottom
      anchors.bottomMargin: Style.spacing.md
      visible: opacity > 0.01
      opacity: (!win.followTail && messageRepeater.count > 0) ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160 } }
      width: jumpLabel.implicitWidth + Style.spacing.rowPaddingX * 2
      height: Math.round(Style.spacing.controlHeight * win.fontScale)
      radius: height / 2
      color: win.background
      border.width: 1
      border.color: client.unread > 0 ? win.accent : win.rule

      Text {
        id: jumpLabel
        anchors.centerIn: parent
        text: client.unread > 0
          ? (client.unread + (client.unread === 1 ? " new message ↓" : " new messages ↓"))
          : "Latest ↓"
        color: client.unread > 0 ? win.accent : win.muted
        font.family: win.fontFamily
        font.pixelSize: win.captionSize
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: win.jumpToLatest()
      }
    }

    Rectangle {
      id: composerRule
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: composerArea.top
      height: 1
      color: win.rule
    }

    // ------------------------------------------------------------ composer
    Item {
      id: composerArea
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: composerColumn.implicitHeight + win.pad * 2

      MouseArea { anchors.fill: parent; onClicked: win.focusComposer() }

      Column {
        id: composerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: win.pad
        anchors.rightMargin: win.pad
        anchors.topMargin: win.pad
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            id: chevron
            text: ">"
            color: composer.activeFocus ? win.accent : win.muted
            font.family: win.fontFamily
            font.pixelSize: win.bodySize
          }

          // The draft grows with what you are writing and then stops at a
          // third of the window, after which it scrolls under the caret
          // instead of eating the transcript.
          Flickable {
            id: composerScroll
            width: parent.width - chevron.width - Style.spacing.md
            readonly property int oneLine: Math.round(win.bodySize * 1.45)
            height: Math.max(oneLine,
              Math.min(composer.contentHeight, Math.round(win.height / 3)))
            contentWidth: width
            contentHeight: composer.contentHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Behavior on height {
              NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
            }

            function revealCaret() {
              var caret = composer.cursorRectangle
              if (caret.y < contentY) contentY = caret.y
              else if (caret.y + caret.height > contentY + height)
                contentY = caret.y + caret.height - height
            }

            TextEdit {
              id: composer
              width: composerScroll.width
              readonly property real lineHeight:
                Math.max(1, contentHeight / Math.max(1, lineCount))
              color: win.foreground
              font.family: win.fontFamily
              font.pixelSize: win.bodySize
              wrapMode: TextEdit.Wrap
              textFormat: TextEdit.PlainText
              selectByMouse: true
              selectionColor: Util.alpha(win.accent, 0.32)
              selectedTextColor: win.foreground
              cursorVisible: activeFocus
              onTextChanged: if (win.composerError !== "") win.composerError = ""
              onCursorRectangleChanged: composerScroll.revealCaret()

              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                visible: composer.text === ""
                text: client.linkList.length === 0
                  ? "Configure a Subspace to start talking…"
                  : (client.connected ? "Say something to the agents…"
                                      : "Waiting for a connection…")
                color: Util.alpha(win.foreground, 0.38)
                font.family: win.fontFamily
                font.pixelSize: win.bodySize
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if ((event.modifiers & Qt.ShiftModifier) !== 0) return
                  win.submit()
                  event.accepted = true
                  return
                }
                if (win.handleKey(event, true)) event.accepted = true
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: win.composerError !== "" ? win.composerError
            : (client.connectionState === "reconnecting" && client.connectionDetail !== ""
               ? "Reconnecting: " + client.connectionDetail : "")
          color: win.urgent
          font.family: win.fontFamily
          font.pixelSize: win.captionSize
          wrapMode: Text.WordWrap
          elide: Text.ElideRight
          maximumLineCount: 2
        }
      }
    }
  }
}
