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

  readonly property color statusColor: {
    if (client.connectionState === "connected") return accent
    if (client.connectionState === "connecting") return muted
    return urgent
  }
  readonly property string statusLabel: {
    if (client.connectionState === "connected") return client.serverName !== "" ? client.serverName : "connected"
    if (client.connectionState === "connecting") return "connecting"
    if (client.connectionState === "reconnecting") return "reconnecting"
    if (client.connectionState === "fatal") return "unavailable"
    if (client.connectionState === "unconfigured") return "not configured"
    return client.connectionState
  }

  // ----------------------------------------------------------- transcript
  property bool followTail: true
  property string unreadAnchorId: ""
  property string composerError: ""

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

  function indexOfMessage(id) {
    if (String(id || "") === "") return -1
    var model = client.messageModel
    for (var index = model.count - 1; index >= 0; index--)
      if (model.get(index).messageId === id) return index
    return -1
  }

  function focusComposer() { composer.forceActiveFocus() }

  function messageArrived(event) {
    // Replayed history is what was already said before this client attached.
    // It is not news, and it must never raise urgency.
    if (event.replay === true) return
    if (event.own === true) { win.clearUnread(); return }
    if (win.isFocused()) { win.clearUnread(); return }

    if (win.unreadAnchorId === "") win.unreadAnchorId = String(event.id || "")
    client.unread += 1
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

  function clearUnread() {
    client.unread = 0
  }

  // The "new" mark outlives the unread count on purpose: the count answers
  // "is there anything?", the mark answers "where did I stop?". It goes away
  // when you have actually caught up, not the moment you glance at the window.
  function clearUnreadMarkIfCaughtUp() {
    if (win.unreadAnchorId === "") return
    if (!transcript.atYEnd || !win.isFocused()) return
    win.unreadAnchorId = ""
  }

  function sendFailed(text, detail) {
    win.composerError = detail
    if (composer.text === "") composer.text = text
  }

  function submit() {
    var body = composer.text
    if (body.replace(/\s+/g, "") === "") return
    if (!client.send(body)) {
      win.composerError = "Not connected to Subspace yet."
      return
    }
    win.composerError = ""
    composer.text = ""
    win.followTail = true
    physics.glideToEnd()
  }

  onVisibleChanged: {
    if (!visible) return
    // Coming back to a window with a backlog should land you where you stopped
    // reading, not at the bottom past everything you missed.
    var resume = win.indexOfMessage(win.unreadAnchorId)
    win.clearUnread()
    Qt.callLater(function() {
      if (resume >= 0) {
        win.followTail = false
        transcript.positionViewAtIndex(resume, ListView.Beginning)
      } else {
        win.followTail = true
        transcript.positionViewAtEnd()
      }
      composer.forceActiveFocus()
    })
  }

  // ------------------------------------------------------- key handling
  // A focused TextEdit claims navigation keys before a window Shortcut can see
  // them, so every text surface routes its keys through here.
  function handleKey(event, inComposer) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0

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

  function scrollImpulse(direction, page) {
    win.followTail = false
    physics.keyImpulse(direction, page)
  }

  function jumpToStart() {
    win.followTail = false
    physics.stopAll()
    transcript.positionViewAtBeginning()
  }

  function jumpToLatest() {
    win.followTail = true
    win.clearUnread()
    win.unreadAnchorId = ""
    physics.stopAll()
    transcript.positionViewAtEnd()
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

    // -------------------------------------------------------------- header
    Item {
      id: header
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Math.round(Style.space(42) * win.fontScale)

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.panelPadding
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

        Text {
          text: win.statusLabel
          color: client.connected ? win.muted : win.statusColor
          font.family: win.fontFamily
          font.pixelSize: win.captionSize
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.panelPadding
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xl

        Text {
          text: client.resolvedIdentity
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
    ListView {
      id: transcript
      anchors.top: headerRule.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: composerRule.top
      anchors.leftMargin: Style.spacing.panelPadding
      anchors.rightMargin: Style.spacing.panelPadding
      anchors.topMargin: Style.spacing.lg
      anchors.bottomMargin: Style.spacing.panelPadding
      clip: true
      model: client.messageModel
      spacing: Style.space(6)
      cacheBuffer: 800
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      maximumFlickVelocity: 6000
      flickDeceleration: 650

      onContentYChanged: {
        physics.stopCoastAtBoundary()
        if (atYEnd) {
          win.followTail = true
          win.clearUnreadMarkIfCaughtUp()
        }
      }
      // Delegate heights are not known when the row is appended, so following
      // the tail has to be re-asserted as the transcript settles, not once.
      onContentHeightChanged: if (win.followTail && !physics.coasting) tailSettle.restart()
      onCountChanged: if (win.followTail) tailSettle.restart()

      Timer {
        id: tailSettle
        interval: 16
        repeat: false
        onTriggered: {
          if (!win.followTail || physics.coasting) return
          transcript.positionViewAtEnd()
        }
      }

      delegate: MessageRow {
        width: transcript.width
        host: win
      }

      WheelHandler {
        target: null
        blocking: true
        acceptedButtons: Qt.NoButton
        acceptedDevices: PointerDevice.TouchPad | PointerDevice.Mouse
        onWheel: function(wheel) { physics.handleWheel(wheel) }
      }
    }

    // Kept outside the ListView on purpose: a Flickable's plain children are
    // parented into the scrolling content item, so anything anchored to
    // "parent" in there quietly scrolls away with the transcript.
    ScrollPhysics {
      id: physics
      surface: transcript
      lineImpulse: client.keyboardLineImpulse
      deceleration: client.keyboardDeceleration
      step: Math.round(Style.space(44) * win.fontScale)
      onUserScrolled: win.followTail = false
    }

    // Empty state. A firehose with nothing on it looks identical to a broken
    // client unless the client says which one it is.
    Text {
      anchors.centerIn: transcript
      visible: transcript.count === 0
      width: transcript.width * 0.7
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
      opacity: (!win.followTail && transcript.count > 0) ? 1 : 0
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
      height: composerColumn.implicitHeight + Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: win.focusComposer() }

      Column {
        id: composerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: Style.spacing.panelPadding
        anchors.rightMargin: Style.spacing.panelPadding
        anchors.topMargin: Math.round(Style.spacing.panelPadding / 2)
        spacing: Style.spacing.sm

        Row {
          width: parent.width
          spacing: Style.spacing.md

          Text {
            id: chevron
            text: ">"
            color: composer.activeFocus ? win.accent : win.muted
            font.family: win.fontFamily
            font.pixelSize: win.bodySize
            y: Math.round((composer.lineHeight - implicitHeight) / 2)
          }

          TextEdit {
            id: composer
            width: parent.width - chevron.width - Style.spacing.md
            height: Math.min(contentHeight, win.height * 0.35)
            readonly property real lineHeight: Math.max(1, contentHeight / Math.max(1, lineCount))
            color: win.foreground
            font.family: win.fontFamily
            font.pixelSize: win.bodySize
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.PlainText
            selectByMouse: true
            selectionColor: Util.alpha(win.accent, 0.32)
            selectedTextColor: win.background
            cursorVisible: activeFocus
            onTextChanged: if (win.composerError !== "") win.composerError = ""

            Text {
              anchors.left: parent.left
              anchors.top: parent.top
              visible: composer.text === ""
              text: client.connected ? "Say something to the agents…"
                                     : "Waiting for a connection…"
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
