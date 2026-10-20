import QtQuick

// The closed view's session count: 12 px semibold tabular digits; a changed
// number rolls in like SwiftUI's .numericText() transition.
Item {
    id: root
    property int value: 0

    implicitWidth: current.implicitWidth
    implicitHeight: current.implicitHeight
    width: implicitWidth
    height: implicitHeight
    clip: false

    property int shown: value
    property int previous: value

    onValueChanged: {
        if (value === shown)
            return
        previous = shown
        const up = value > shown
        shown = value
        roll.stop()
        outgoing.direction = up ? -1 : 1
        roll.start()
    }

    Text {
        id: outgoing
        property real direction: -1
        text: root.previous
        opacity: 0
        color: Qt.rgba(1, 1, 1, 0.85)
        font.pixelSize: 12
        font.weight: Font.DemiBold
        font.features: ({ "tnum": 1 })
    }

    Text {
        id: current
        text: root.shown
        color: Qt.rgba(1, 1, 1, 0.85)
        font.pixelSize: 12
        font.weight: Font.DemiBold
        font.features: ({ "tnum": 1 })
    }

    ParallelAnimation {
        id: roll
        NumberAnimation { target: outgoing; property: "opacity"; from: 1; to: 0; duration: 300; easing.type: Easing.OutCubic }
        NumberAnimation { target: outgoing; property: "y"; from: 0; to: outgoing.direction * 6; duration: 300; easing.type: Easing.OutCubic }
        NumberAnimation { target: current; property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.OutCubic }
        NumberAnimation { target: current; property: "y"; from: -outgoing.direction * 6; to: 0; duration: 300; easing.type: Easing.OutCubic }
    }
}
