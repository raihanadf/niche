import QtQuick
import org.kde.kirigami as Kirigami

// niche's SkipGlyph: two triangles; on play() the leading one shrinks away,
// the trailing one slides into its place and a new one grows in behind
// (0.38 s). Mirrored for skipping back.
Item {
    id: root

    property bool forward: true
    property real progress: 0
    readonly property real step: 12.5
    readonly property real iconSize: 16
    readonly property real center: (width - iconSize) / 2

    function play() {
        run.restart();
    }

    implicitWidth: step + iconSize
    implicitHeight: iconSize

    transform: Scale {
        origin.x: root.width / 2
        xScale: root.forward ? 1 : -1
    }

    Repeater {
        model: 3

        Kirigami.Icon {
            required property int index
            readonly property real fade: Math.max(0, 1 - 2 * root.progress)
            readonly property real grow: Math.min(1, Math.max(0, (root.progress - 0.25) / 0.75))
            readonly property real appear: Math.min(1, Math.max(0, (root.progress - 0.25) / 0.5))

            // 0: leading triangle leaving, 1: trailing one sliding forward,
            // 2: new trailing one growing in.
            x: root.center + (index === 0 ? root.step / 2 : index === 1 ? -root.step / 2 + root.step * Math.min(1, 2 * root.progress) : -root.step / 2)
            y: (root.height - height) / 2
            width: root.iconSize
            height: root.iconSize
            scale: index === 0 ? fade : index === 2 ? grow : 1
            opacity: index === 0 ? fade : index === 2 ? appear : 1
            transformOrigin: index === 0 ? Item.Right : Item.Center
            source: "media-playback-start"
            color: "white"
            isMask: true
            roundToIconSize: false
        }
    }

    NumberAnimation {
        id: run

        target: root
        property: "progress"
        from: 0
        to: 1
        duration: 380
        easing.type: Easing.InOutCubic
        // The end frame looks exactly like the start frame.
        onFinished: root.progress = 0
    }
}
