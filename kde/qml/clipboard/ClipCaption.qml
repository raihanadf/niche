import QtQuick
import QtQuick.Layouts
import Niche

// Line under the tiles (niche's ClipCaption): first line of the focused item,
// how long ago it was copied, and "⏎ paste" (keyboard) or "Clear" (pointer).
RowLayout {
    id: caption

    property string label: ""
    property var date: null
    property bool keyboard: false

    signal clearClicked()

    height: 14
    spacing: 6

    property real now: Date.now()

    function age(date, now) {
        if (!date)
            return ""
        const seconds = Math.floor((now - date.getTime()) / 1000)
        if (seconds < 60)
            return "now"
        if (seconds < 3600)
            return Math.floor(seconds / 60) + "m"
        if (seconds < 86400)
            return Math.floor(seconds / 3600) + "h"
        return Math.floor(seconds / 86400) + "d"
    }

    onDateChanged: now = Date.now()
    onVisibleChanged: if (visible) now = Date.now()

    Timer {
        interval: 30000
        repeat: true
        running: caption.visible
        onTriggered: caption.now = Date.now()
    }

    Text {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: caption.label
        textFormat: Text.PlainText
        color: Qt.rgba(1, 1, 1, 0.8)
        font.pixelSize: 11
        font.weight: Font.Medium
        elide: Text.ElideMiddle
        maximumLineCount: 1
    }

    Text {
        text: caption.age(caption.date, caption.now)
        color: Qt.rgba(1, 1, 1, 0.4)
        font.pixelSize: 10
        font.weight: Font.Medium
        font.features: { "tnum": 1 }
    }

    Text {
        visible: caption.keyboard
        text: Clipboard.pastesOnPick && Clipboard.canPaste ? "⏎ paste" : "⏎ copy"
        color: Qt.rgba(1, 1, 1, 0.4)
        font.pixelSize: 10
        font.weight: Font.Medium
    }

    Text {
        visible: !caption.keyboard
        text: "Clear"
        color: Qt.rgba(1, 1, 1, clearArea.containsMouse ? 0.75 : 0.5)
        font.pixelSize: 10
        font.weight: Font.DemiBold

        MouseArea {
            id: clearArea
            anchors.fill: parent
            anchors.margins: -3
            hoverEnabled: true
            onClicked: caption.clearClicked()
        }
    }
}
