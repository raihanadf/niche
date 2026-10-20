import QtQuick
import QtQuick.Shapes

// niche's BatteryRing: a small ring that fills to the battery level, pulsing
// when low, followed by the percentage.
Row {
    id: ring

    property real level: 0
    property bool low: false
    readonly property color tint: level <= 0.1 ? "#FF453A" : level <= 0.2 ? "#FF9F0A" : "#30D158"
    property real shown: 0
    property bool appeared: false

    spacing: 3

    onLevelChanged: {
        if (appeared) {
            appearAnimation.stop();
            changeAnimation.restart();
        }
    }
    Component.onCompleted: {
        appeared = true;
        appearAnimation.start();
    }

    Item {
        id: dial
        anchors.verticalCenter: parent.verticalCenter
        width: 10
        height: 10

        SequentialAnimation on opacity {
            running: ring.low
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: Qt.rgba(1, 1, 1, 0.2)
                strokeWidth: 2.2
                fillColor: "transparent"
                PathAngleArc { centerX: 5; centerY: 5; radiusX: 5; radiusY: 5; startAngle: 0; sweepAngle: 360 }
            }
        }

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: ring.shown > 0.005

            ShapePath {
                strokeColor: ring.tint
                strokeWidth: 2.2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc { centerX: 5; centerY: 5; radiusX: 5; radiusY: 5; startAngle: -90; sweepAngle: 360 * Math.min(ring.shown, 1) }
            }
        }
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Math.round(ring.level * 100) + "%"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.features: ({ "tnum": 1 })
        color: ring.low ? ring.tint : Qt.rgba(1, 1, 1, 0.85)
    }

    SequentialAnimation {
        id: appearAnimation
        PauseAnimation { duration: 150 }
        NumberAnimation { target: ring; property: "shown"; to: ring.level; duration: 600; easing.type: Easing.OutBack; easing.overshoot: 0.6 }
    }

    NumberAnimation {
        id: changeAnimation
        target: ring
        property: "shown"
        to: ring.level
        duration: 250
        easing.type: Easing.OutCubic
    }
}
