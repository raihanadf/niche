import QtQuick
import QtQuick.Effects

// niche's IdleArtView: the island picture (GIF or still), trimmed to the
// square around its opaque pixels and clipped to rounded corners.
Item {
    id: root
    property url source
    property rect crop: Qt.rect(0, 0, 1, 1)
    property real size: 20
    property real radius: 5
    property bool playing: visible

    width: size
    height: size

    Item {
        id: picture
        anchors.fill: parent
        clip: true
        layer.enabled: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: mask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }

        AnimatedImage {
            source: root.source
            playing: root.playing && frameCount > 1
            cache: false
            smooth: true
            mipmap: true
            fillMode: Image.Stretch
            width: root.size / Math.max(root.crop.width, 0.0001)
            height: root.size / Math.max(root.crop.height, 0.0001)
            x: -root.crop.x * width
            y: -root.crop.y * height
        }
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        radius: root.radius
        visible: false
        layer.enabled: true
    }
}
