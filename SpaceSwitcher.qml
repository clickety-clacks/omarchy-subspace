import QtQuick
import qs.Commons

// The Subspace picker: switch between configured servers, and add, edit or
// remove them without leaving the window for a text editor.
//
// It is a layer inside the window rather than a popup window, so it inherits
// the theme, the font scale, and the compositor's idea of where the app is.
Item {
  id: switcher

  required property var client
  required property var host

  readonly property color foreground: host.foreground
  readonly property color background: host.background
  readonly property color accent: host.accent
  readonly property color muted: host.muted
  readonly property color urgent: host.urgent
  readonly property string fontFamily: host.fontFamily

  property bool open: false
  property int selected: 0
  // -1 is the "add" form; >= 0 edits that space. Anything else is the list.
  property int editing: -2
  property string draftName: ""
  property string draftServers: ""
  property string draftError: ""

  readonly property int rowCount: client.linkList.length
  readonly property bool editingForm: editing !== -2

  visible: open
  anchors.fill: parent

  function show() {
    switcher.selected = Math.max(0, Math.min(client.activeIndex, rowCount - 1))
    switcher.editing = -2
    switcher.draftError = ""
    switcher.open = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function hide() {
    switcher.open = false
    switcher.editing = -2
    host.focusComposer()
  }

  function toggle() { switcher.open ? hide() : show() }

  function chooseSelected() {
    if (rowCount === 0) { beginAdd(); return }
    client.selectSpace(switcher.selected)
    hide()
  }

  function beginAdd() {
    switcher.editing = -1
    switcher.draftName = ""
    switcher.draftServers = ""
    switcher.draftError = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function beginEdit(index) {
    var space = client.spaceList[index]
    if (!space) return
    switcher.editing = index
    switcher.draftName = String(space.name || "")
    switcher.draftServers = space.servers.join(", ")
    switcher.draftError = ""
    Qt.callLater(function() { nameField.forceActiveFocus() })
  }

  function commitDraft() {
    var ok = switcher.editing === -1
      ? client.addSpace(switcher.draftName, switcher.draftServers)
      : client.updateSpace(switcher.editing, switcher.draftName, switcher.draftServers)
    if (!ok) {
      switcher.draftError = switcher.draftServers.trim() === ""
        ? "A Subspace needs a server address."
        : "That does not look like a server address. Try http://host:4000."
      return
    }
    switcher.editing = -2
    switcher.draftError = ""
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function cancelDraft() {
    switcher.editing = -2
    switcher.draftError = ""
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function removeSelected() {
    if (rowCount === 0) return
    client.removeSpace(switcher.selected)
    switcher.selected = Math.max(0, Math.min(switcher.selected, rowCount - 2))
  }

  function move(step) {
    if (rowCount === 0) return
    switcher.selected = (switcher.selected + step + rowCount) % rowCount
  }

  // Clicking away closes it. The scrim also keeps clicks off the transcript
  // underneath, which would otherwise move focus out from under the list.
  Rectangle {
    anchors.fill: parent
    color: Util.alpha(switcher.background, 0.55)

    MouseArea {
      anchors.fill: parent
      onClicked: switcher.hide()
    }
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: switcher.open
    Keys.onPressed: function(event) {
      if (switcher.editingForm) {
        if (event.key === Qt.Key_Escape) { switcher.cancelDraft(); event.accepted = true }
        return
      }
      switch (event.key) {
      case Qt.Key_Escape: switcher.hide(); break
      case Qt.Key_Up: case Qt.Key_K: switcher.move(-1); break
      case Qt.Key_Down: case Qt.Key_J: switcher.move(1); break
      case Qt.Key_Return: case Qt.Key_Enter: switcher.chooseSelected(); break
      case Qt.Key_N: switcher.beginAdd(); break
      case Qt.Key_E: if (switcher.rowCount > 0) switcher.beginEdit(switcher.selected); break
      case Qt.Key_Delete: case Qt.Key_Backspace: switcher.removeSelected(); break
      default:
        // 1-9 jump straight to a space, matching the window's own Alt+N.
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          var index = event.key - Qt.Key_1
          if (index < switcher.rowCount) { switcher.selected = index; switcher.chooseSelected() }
          break
        }
        return
      }
      event.accepted = true
    }
  }

  Rectangle {
    id: card
    x: host.pad
    y: host.pad
    width: Math.min(Math.max(Style.space(320), parent.width - host.pad * 2),
                    Math.round(Style.space(420) * host.fontScale))
    height: Math.min(parent.height - host.pad * 2, body.implicitHeight + Style.spacing.lg * 2)
    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
    // Menu surfaces are allowed to be translucent because the shell blurs
    // behind them. There is no blur here, so a themed alpha just lets the
    // header show through the list. Take the theme's colour, drop its alpha.
    color: Qt.rgba(Color.menu.background.r, Color.menu.background.g,
                   Color.menu.background.b, 1)
    border.width: 1
    border.color: Util.alpha(switcher.accent, 0.45)

    // Swallow clicks so the scrim behind does not close the card.
    MouseArea { anchors.fill: parent }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.spacing.lg
      spacing: Style.spacing.md

      Text {
        text: "SUBSPACES"
        color: switcher.muted
        font.family: switcher.fontFamily
        font.pixelSize: host.captionSize
        font.letterSpacing: 1
      }

      Repeater {
        model: switcher.client.linkList

        delegate: Rectangle {
          id: row
          required property var modelData
          required property int index
          readonly property bool current: switcher.selected === index
          readonly property bool active: switcher.client.activeIndex === index

          width: body.width
          height: rowBody.implicitHeight + Style.spacing.md * 2
          radius: Style.space(4)
          color: row.current ? Style.selectedAccentFill
            : (rowArea.containsMouse ? Style.hoverFill : "transparent")

          Rectangle {
            width: Style.space(2)
            height: parent.height - Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            color: row.active ? switcher.accent : "transparent"
            radius: width
          }

          Column {
            id: rowBody
            anchors.left: parent.left
            anchors.right: removeButton.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.spacing.sm

              Rectangle {
                width: Math.round(host.captionSize * 0.5)
                height: width
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: row.modelData.connected ? switcher.accent : switcher.urgent
                opacity: row.modelData.connected ? 0.95 : 0.75
              }

              Text {
                text: row.modelData.displayName
                anchors.verticalCenter: parent.verticalCenter
                color: switcher.foreground
                font.family: switcher.fontFamily
                font.pixelSize: host.bodySize
                // Unread is worth more than active here: the whole reason to
                // open this list is to find out where something was said.
                font.weight: row.modelData.unread > 0 || row.active
                  ? Font.DemiBold : Font.Normal
              }

              // Something was said here since you last looked. A filled mark
              // rather than a bare number: the leading dot on this row already
              // means "connected", and a lone digit beside it reads as part of
              // the name rather than as news. It carries the count when there
              // is room for it, and stays a dot when there is not.
              Rectangle {
                id: unreadMark
                visible: row.modelData.unread > 0
                anchors.verticalCenter: parent.verticalCenter
                readonly property int diameter: Math.round(host.bodySize * 0.62)
                width: Math.max(diameter, unreadCount.implicitWidth + diameter * 0.7)
                height: diameter
                radius: height / 2
                color: switcher.accent

                Text {
                  id: unreadCount
                  anchors.centerIn: parent
                  text: row.modelData.unread > 99 ? "99+" : row.modelData.unread
                  color: switcher.background
                  font.family: switcher.fontFamily
                  font.pixelSize: Math.round(host.captionSize * 0.85)
                  font.weight: Font.Bold
                }
              }
            }

            Text {
              width: rowBody.width
              text: row.modelData.servers.join("  ·  ")
              color: switcher.muted
              font.family: switcher.fontFamily
              font.pixelSize: host.captionSize
              elide: Text.ElideRight
            }
          }

          Text {
            id: removeButton
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            text: "✕"
            color: removeArea.containsMouse ? switcher.urgent : Util.alpha(switcher.foreground, 0.4)
            font.family: switcher.fontFamily
            font.pixelSize: host.captionSize

            MouseArea {
              id: removeArea
              anchors.fill: parent
              anchors.margins: -Style.spacing.sm
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                switcher.selected = row.index
                switcher.removeSelected()
              }
            }
          }

          MouseArea {
            id: rowArea
            anchors.fill: parent
            anchors.rightMargin: Style.spacing.xxl
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { switcher.selected = row.index; switcher.chooseSelected() }
            onDoubleClicked: switcher.beginEdit(row.index)
          }
        }
      }

      Text {
        visible: switcher.rowCount === 0 && !switcher.editingForm
        width: body.width
        wrapMode: Text.WordWrap
        text: "No Subspace configured yet. Add the address of one and this "
          + "becomes a chat window."
        color: switcher.muted
        font.family: switcher.fontFamily
        font.pixelSize: host.captionSize
      }

      Rectangle {
        width: body.width
        height: 1
        color: Util.alpha(switcher.foreground, 0.12)
      }

      // ------------------------------------------------------------- form
      Column {
        visible: switcher.editingForm
        width: body.width
        spacing: Style.spacing.sm

        SwitcherField {
          id: nameField
          width: parent.width
          host: switcher.host
          label: "Name"
          placeholder: "optional — the server's own name is used otherwise"
          text: switcher.draftName
          onTextEdited: switcher.draftName = value
          onSubmitted: serversField.forceActiveFocus()
          onCancelled: switcher.cancelDraft()
        }

        SwitcherField {
          id: serversField
          width: parent.width
          host: switcher.host
          label: "Server"
          placeholder: "http://10.0.0.2:4000"
          text: switcher.draftServers
          onTextEdited: switcher.draftServers = value
          onSubmitted: switcher.commitDraft()
          onCancelled: switcher.cancelDraft()
        }

        Text {
          visible: switcher.draftError !== ""
          width: parent.width
          text: switcher.draftError
          wrapMode: Text.WordWrap
          color: switcher.urgent
          font.family: switcher.fontFamily
          font.pixelSize: host.captionSize
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Several addresses, comma separated, are fallbacks for this one "
            + "Subspace — tried in order. Return saves, Esc cancels."
          color: Util.alpha(switcher.foreground, 0.45)
          font.family: switcher.fontFamily
          font.pixelSize: host.captionSize
        }
      }

      // -------------------------------------------------------------- add
      Rectangle {
        visible: !switcher.editingForm
        width: body.width
        height: addLabel.implicitHeight + Style.spacing.md * 2
        radius: Style.space(4)
        color: addArea.containsMouse ? Style.hoverFill : "transparent"

        Text {
          id: addLabel
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.rowPaddingX
          anchors.verticalCenter: parent.verticalCenter
          text: "+  Add a Subspace"
          color: addArea.containsMouse ? switcher.foreground : switcher.muted
          font.family: switcher.fontFamily
          font.pixelSize: host.bodySize
        }

        MouseArea {
          id: addArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: switcher.beginAdd()
        }
      }

      Text {
        visible: !switcher.editingForm && switcher.rowCount > 0
        width: body.width
        wrapMode: Text.WordWrap
        text: "Return switches · E edits · ✕ or Delete removes · Esc closes"
        color: Util.alpha(switcher.foreground, 0.45)
        font.family: switcher.fontFamily
        font.pixelSize: host.captionSize
      }
    }
  }
}
