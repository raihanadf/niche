import QtQuick
import QtQuick.Shapes
import Niche

// niche's LockIndicator: a padlock in the left slot that latches on lock and
// springs open on unlock.
Item {
    id: lock
    property string lockState: "none" // locked | unlocking
    property bool shown: false

    property real lift: 0.8
    property real swing: 180
    property real squash: 1
    property bool appeared: false

    readonly property bool present: shown && appeared
    opacity: present ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }

    onVisibleChanged: if (visible) latch.restart()
    onLockStateChanged: if (lockState === "unlocking") unlatch.restart()
    Component.onCompleted: if (visible) latch.restart()

    SequentialAnimation {
        id: latch
        ScriptAction { script: { lock.appeared = false; lock.lift = 0.8; lock.swing = 180; lock.squash = 1; lock.appeared = true; } }
        PauseAnimation { duration: 550 }
        NumberAnimation { target: lock; property: "swing"; to: 0; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        NumberAnimation { target: lock; property: "lift"; to: 0; duration: 250; easing.type: Easing.OutBack; easing.overshoot: 2 }
        NumberAnimation { target: lock; property: "squash"; to: 0.88; duration: 50; easing.type: Easing.OutQuad }
        NumberAnimation { target: lock; property: "squash"; to: 1; duration: 250; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 0.4 }
    }

    SequentialAnimation {
        id: unlatch
        ScriptAction { script: latch.stop() }
        NumberAnimation { target: lock; property: "squash"; to: 0.88; duration: 60; easing.type: Easing.OutQuad }
        ParallelAnimation {
            NumberAnimation { target: lock; property: "squash"; to: 1; duration: 280; easing.type: Easing.OutElastic; easing.amplitude: 1; easing.period: 0.35 }
            NumberAnimation { target: lock; property: "lift"; to: 0.8; duration: 280; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
            SequentialAnimation {
                PauseAnimation { duration: 100 }
                NumberAnimation { target: lock; property: "swing"; to: 180; duration: 350; easing.type: Easing.OutBack; easing.overshoot: 1.4 }
            }
        }
    }

    Item {
        id: glyph
        width: 13
        height: 14
        x: Metrics.capCenter - width / 2
        y: (lock.height - height) / 2
        scale: lock.present ? 1 : 0.85
        transformOrigin: Item.Left
        Behavior on scale { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }

        Shape {
            id: shackle
            readonly property real t: lock.swing / 180
            width: 6 - 1.2 * t
            height: 8 - 2 * t
            x: (glyph.width - width) / 2
            y: glyph.height - height - 4.1 - lock.lift
            preferredRendererType: Shape.CurveRenderer
            transform: Scale {
                origin.x: shackle.width
                xScale: Math.cos(lock.swing * Math.PI / 180)
            }

            ShapePath {
                strokeColor: "white"
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                startX: 0
                startY: shackle.height
                PathLine { x: 0; y: shackle.width / 2 }
                PathArc { x: shackle.width; y: shackle.width / 2; radiusX: shackle.width / 2; radiusY: shackle.width / 2 }
                PathLine { x: shackle.width; y: shackle.height }
            }
        }

        Rectangle {
            width: 8.8
            height: 6.6
            radius: 1.9
            color: "white"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            transform: Scale {
                origin.x: 4.4
                origin.y: 6.6
                xScale: 2 - lock.squash
                yScale: lock.squash
            }
        }
    }
}
