import QtQuick

// niche's LevelBar: a 34 × 5 capsule track with a white fill.
Item {
    id: bar

    property real level: 0
    property real shown: Math.max(0, Math.min(1, level))
    Behavior on shown { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

    implicitWidth: 34
    implicitHeight: 5

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.2)
    }

    Rectangle {
        width: parent.width * bar.shown
        height: parent.height
        radius: height / 2
        color: "white"
        visible: width > 0.5
    }
}
