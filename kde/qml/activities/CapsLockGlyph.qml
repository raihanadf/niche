import QtQuick
import QtQuick.Shapes

// SF Symbols' capslock / capslock.fill: an arrow over a bar, filled when lit.
Item {
    id: glyph

    property bool lit: false
    property color color: "white"
    Behavior on color { ColorAnimation { duration: 200 } }

    implicitWidth: 16
    implicitHeight: 16

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: glyph.color
            strokeWidth: 1.5
            fillColor: glyph.lit ? glyph.color : "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            startX: 8; startY: 1.8
            PathLine { x: 14.2; y: 8 }
            PathLine { x: 10.6; y: 8 }
            PathLine { x: 10.6; y: 10.8 }
            PathLine { x: 5.4; y: 10.8 }
            PathLine { x: 5.4; y: 8 }
            PathLine { x: 1.8; y: 8 }
            PathLine { x: 8; y: 1.8 }
        }

        ShapePath {
            strokeColor: glyph.color
            strokeWidth: 1.5
            fillColor: glyph.lit ? glyph.color : "transparent"
            joinStyle: ShapePath.RoundJoin
            startX: 5.4; startY: 13
            PathLine { x: 10.6; y: 13 }
            PathLine { x: 10.6; y: 14.6 }
            PathLine { x: 5.4; y: 14.6 }
            PathLine { x: 5.4; y: 13 }
        }
    }
}
