import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import org.kde.kirigami as Kirigami

// niche's HeadphonesGlyph: the headphones drop in with a tilt and a blur on
// connect, sag and get struck through on disconnect.
Item {
    id: glyph

    property string iconName: "audio-headphones-symbolic"
    property bool connected: true

    property real poseScale: 1
    property real poseY: 0
    property real poseTilt: 0
    property real poseBlur: 0
    property real slash: 0

    implicitWidth: 22
    implicitHeight: 18

    function play() {
        connectAnimation.stop();
        disconnectAnimation.stop();
        slashAnimation.stop();
        slash = 0;
        if (connected) {
            poseScale = 0.55;
            poseY = -5;
            poseTilt = -14;
            poseBlur = 4;
            connectAnimation.start();
        } else {
            poseScale = 1;
            poseY = 0;
            poseTilt = 0;
            poseBlur = 0;
            disconnectAnimation.start();
            slashAnimation.start();
        }
    }

    Component.onCompleted: play()
    onConnectedChanged: play()

    Kirigami.Icon {
        anchors.centerIn: parent
        width: 18
        height: 18
        source: glyph.iconName
        isMask: true
        color: "white"
        scale: glyph.poseScale
        rotation: glyph.poseTilt
        transform: Translate { y: glyph.poseY }
        opacity: glyph.connected ? 1 : 0.45
        Behavior on opacity {
            SequentialAnimation {
                PauseAnimation { duration: 120 }
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
        }
        layer.enabled: glyph.poseBlur > 0.05
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 8
            blur: glyph.poseBlur / 8
        }
    }

    // SlashLine: black under-stroke cuts the glyph, white stroke on top.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: glyph.slash > 0.01

        ShapePath {
            strokeColor: "black"
            strokeWidth: 4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: 5; startY: 2.5
            PathLine { x: 5 + (glyph.width - 10) * glyph.slash; y: 2.5 + (glyph.height - 5) * glyph.slash }
        }
        ShapePath {
            strokeColor: "white"
            strokeWidth: 1.6
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: 5; startY: 2.5
            PathLine { x: 5 + (glyph.width - 10) * glyph.slash; y: 2.5 + (glyph.height - 5) * glyph.slash }
        }
    }

    ParallelAnimation {
        id: connectAnimation
        SequentialAnimation {
            NumberAnimation { target: glyph; property: "poseScale"; to: 1.12; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { target: glyph; property: "poseScale"; to: 1; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        }
        NumberAnimation { target: glyph; property: "poseY"; to: 0; duration: 500; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        SequentialAnimation {
            NumberAnimation { target: glyph; property: "poseTilt"; to: 6; duration: 200; easing.type: Easing.OutCubic }
            NumberAnimation { target: glyph; property: "poseTilt"; to: 0; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.5 }
        }
        NumberAnimation { target: glyph; property: "poseBlur"; to: 0; duration: 250; easing.type: Easing.InOutCubic }
    }

    ParallelAnimation {
        id: disconnectAnimation
        SequentialAnimation {
            NumberAnimation { target: glyph; property: "poseScale"; to: 0.8; duration: 220; easing.type: Easing.OutCubic }
            NumberAnimation { target: glyph; property: "poseScale"; to: 0.86; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        }
        NumberAnimation { target: glyph; property: "poseY"; to: 2.5; duration: 500; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
        SequentialAnimation {
            NumberAnimation { target: glyph; property: "poseTilt"; to: 10; duration: 200; easing.type: Easing.OutCubic }
            NumberAnimation { target: glyph; property: "poseTilt"; to: 8; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.5 }
        }
    }

    SequentialAnimation {
        id: slashAnimation
        PauseAnimation { duration: 200 }
        NumberAnimation { target: glyph; property: "slash"; from: 0; to: 1; duration: 350; easing.type: Easing.OutCubic }
    }
}
