import QtQuick

// niche's SunGlyph: a disc and eight rays that grow and light up with the level.
Item {
    id: sun

    property real level: 0
    property real shown: Math.max(0, Math.min(1, level))
    Behavior on shown { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

    readonly property color tint: "#FFD60A"

    implicitWidth: 16
    implicitHeight: 16

    Rectangle {
        readonly property real diameter: 4.6 + 1.2 * sun.shown
        anchors.centerIn: parent
        width: diameter
        height: diameter
        radius: diameter / 2
        color: sun.tint
    }

    Repeater {
        model: 8

        Item {
            required property int index
            width: sun.width
            height: sun.height
            rotation: index * 45

            Rectangle {
                readonly property real rayHeight: 1.2 + 1.8 * sun.shown
                readonly property real distance: 4.6 + 1.5 * sun.shown
                x: (parent.width - width) / 2
                y: parent.height / 2 - distance - rayHeight / 2
                width: 1.4
                height: rayHeight
                radius: width / 2
                color: sun.tint
                opacity: Math.min(Math.max(sun.shown * 8 - parent.index, 0.3), 1)
            }
        }
    }
}
