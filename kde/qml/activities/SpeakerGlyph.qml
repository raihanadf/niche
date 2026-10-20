import QtQuick
import QtQuick.Shapes

// SF Symbols' speaker.wave.3.fill with a variable value (waves light up with
// the level), or speaker.slash.fill when muted.
Item {
    id: glyph

    property real level: 0
    property bool muted: false
    property color color: "white"

    implicitWidth: 16
    implicitHeight: 16

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillColor: glyph.color
            PathSvg { path: "M 1.8 5.8 L 4.2 5.8 L 8 2.8 L 8 13.2 L 4.2 10.2 L 1.8 10.2 Q 1.2 10.2 1.2 9.6 L 1.2 6.4 Q 1.2 5.8 1.8 5.8 Z" }
        }
    }

    Repeater {
        model: 3

        Shape {
            id: wave
            required property int index
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            visible: !glyph.muted
            opacity: glyph.level > index / 3 + 0.001 ? 1 : 0.3
            Behavior on opacity { NumberAnimation { duration: 200 } }

            ShapePath {
                strokeColor: glyph.color
                strokeWidth: 1.4
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 8
                    centerY: 8
                    radiusX: 2.6 + 2 * wave.index
                    radiusY: 2.6 + 2 * wave.index
                    startAngle: -40
                    sweepAngle: 80
                }
            }
        }
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: glyph.muted

        ShapePath {
            strokeColor: "black"
            strokeWidth: 3.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: 2.5; startY: 2.5
            PathLine { x: 13.5; y: 13.5 }
        }
        ShapePath {
            strokeColor: glyph.color
            strokeWidth: 1.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            startX: 2.5; startY: 2.5
            PathLine { x: 13.5; y: 13.5 }
        }
    }
}
