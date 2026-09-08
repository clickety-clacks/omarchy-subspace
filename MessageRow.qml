import QtQuick
import qs.Commons

// One line of firehose traffic. Consecutive lines from the same agent inside a
// few minutes are drawn as one run: the name is stated once and the rest is
// just what that agent went on to say.
Item {
  id: row

  required property var host
  required property string messageId
  required property string agentId
  required property string agentName
  required property string body
  required property string timestamp
  required property bool own
  required property bool replay
  required property bool grouped

  readonly property color foreground: host.foreground
  readonly property color accent: host.accent
  readonly property color muted: host.muted
  readonly property int gutter: Style.space(10)
  readonly property bool startsUnread: host.unreadAnchorId !== ""
    && host.unreadAnchorId === messageId

  implicitHeight: content.implicitHeight
  height: implicitHeight

  function localTime(value) {
    var parsed = new Date(value)
    if (isNaN(parsed.getTime())) return ""
    return Qt.formatDateTime(parsed, "HH:mm")
  }

  Column {
    id: content
    width: parent.width
    spacing: Style.space(3)

    // The mark where you stopped reading. It stays until you catch up, so a
    // glance at the transcript still shows how much arrived while you were
    // away, not just that something did.
    Item {
      width: parent.width
      height: row.startsUnread ? unreadMark.implicitHeight + Style.space(8) : 0
      visible: row.startsUnread

      Row {
        id: unreadMark
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md

        Text {
          id: unreadLabel
          text: "new"
          color: row.accent
          font.family: host.fontFamily
          font.pixelSize: host.captionSize
          font.letterSpacing: 1
          anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
          width: Math.max(0, parent.width - parent.spacing - unreadLabel.implicitWidth)
          height: 1
          color: Util.alpha(row.accent, 0.5)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    Item {
      width: parent.width
      height: row.grouped ? 0 : nameRow.implicitHeight + Style.space(4)
      visible: !row.grouped

      Row {
        id: nameRow
        anchors.bottom: parent.bottom
        x: row.gutter
        spacing: Style.spacing.md

        Text {
          text: row.own ? "you" : row.agentName
          color: row.own ? row.accent : row.foreground
          font.family: host.fontFamily
          font.pixelSize: host.captionSize
          font.weight: Font.DemiBold
          anchors.baseline: stamp.baseline
        }

        Text {
          id: stamp
          text: row.localTime(row.timestamp)
          color: Util.alpha(row.muted, 0.85)
          font.family: host.fontFamily
          font.pixelSize: host.captionSize
        }
      }
    }

    Item {
      width: parent.width
      height: bodyText.contentHeight

      // Your own lines carry a rule so you can find them in a busy firehose
      // without the text itself being styled differently.
      Rectangle {
        width: Style.space(2)
        height: parent.height
        color: row.own ? Util.alpha(row.accent, 0.7) : "transparent"
      }

      TextEdit {
        id: bodyText
        x: row.gutter
        width: parent.width - row.gutter
        height: contentHeight
        text: row.body
        color: row.replay ? Util.alpha(row.foreground, 0.82) : row.foreground
        font.family: host.fontFamily
        font.pixelSize: host.bodySize
        wrapMode: TextEdit.Wrap
        textFormat: TextEdit.PlainText
        readOnly: true
        selectByMouse: true
        selectionColor: Util.alpha(row.accent, 0.32)
        selectedTextColor: host.background
        Keys.onPressed: function(event) {
          if (host.handleKey(event, false)) event.accepted = true
        }
      }
    }
  }
}
