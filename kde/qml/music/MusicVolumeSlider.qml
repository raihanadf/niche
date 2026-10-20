import QtQuick

// niche's VolumeSlider: a thin capsule; press or drag anywhere to set the level.
Item {
    id: root

    property real level

    signal moved(real level)

    implicitHeight: 6

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.16)
    }

    Rectangle {
        height: parent.height
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.55)
        width: parent.width * Math.max(0, Math.min(1, root.level))

        Behavior on width {
            NumberAnimation {
                duration: 200
                easing.type: Easing.OutCubic
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.topMargin: -8
        anchors.bottomMargin: -8
        preventStealing: true

        function report(x) {
            root.moved(Math.max(0, Math.min(1, x / root.width)));
        }

        onPressed: mouse => report(mouse.x)
        onPositionChanged: mouse => {
            if (pressed) {
                report(mouse.x);
            }
        }
    }
}
