import QtQuick
import QtQuick.Effects

// MusicCover clipped to a rounded rectangle, with optional blur (px) for
// niche's artwork swap.
Item {
    id: root

    property alias source: cover.source
    property alias animated: cover.animated
    property real radius: 7
    property real blur: 0

    // The next source change shows at once instead of fading.
    function snapNext() {
        cover.instantNext = true;
    }

    function clearSnap() {
        cover.instantNext = false;
    }

    MusicCover {
        id: cover

        anchors.fill: parent
        visible: false
    }

    Item {
        id: mask

        anchors.fill: parent
        visible: false
        layer.enabled: true
        layer.smooth: true

        Rectangle {
            anchors.fill: parent
            radius: root.radius
            color: "black"
            antialiasing: true
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: cover
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
        blurEnabled: root.blur > 0.05
        blurMax: 16
        blur: Math.min(1, root.blur / 16)
    }
}
