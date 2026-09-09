import QtQuick
import qs.Commons

// One labelled single-line input for the Subspace form.
Item {
  id: field

  required property var host
  property string label: ""
  property string placeholder: ""
  property alias text: input.text

  signal textEdited(string value)
  signal submitted()
  signal cancelled()

  implicitHeight: column.implicitHeight
  height: implicitHeight

  function forceActiveFocus() { input.forceActiveFocus() }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(3)

    Text {
      text: field.label
      color: host.muted
      font.family: host.fontFamily
      font.pixelSize: host.captionSize
    }

    Rectangle {
      width: parent.width
      height: input.implicitHeight + Style.spacing.inputPaddingY * 2
      radius: Style.space(4)
      color: Util.alpha(host.foreground, input.activeFocus ? 0.08 : 0.04)
      border.width: 1
      border.color: input.activeFocus
        ? Util.alpha(host.accent, 0.7) : Util.alpha(host.foreground, 0.18)

      TextInput {
        id: input
        anchors.fill: parent
        anchors.leftMargin: Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.controlPaddingX
        verticalAlignment: TextInput.AlignVCenter
        color: host.foreground
        font.family: host.fontFamily
        font.pixelSize: host.bodySize
        selectByMouse: true
        selectionColor: Util.alpha(host.accent, 0.32)
        selectedTextColor: host.foreground
        clip: true
        onTextChanged: field.textEdited(text)
        onAccepted: field.submitted()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { field.cancelled(); event.accepted = true }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: input.text === ""
          text: field.placeholder
          color: Util.alpha(host.foreground, 0.35)
          font.family: host.fontFamily
          font.pixelSize: host.bodySize
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }
  }
}
