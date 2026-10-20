import QtQuick
import QtQuick.Shapes

// SF Symbols' moon.fill: a crescent opening to the upper right.
Item {
    id: glyph

    property color color: "white"
    Behavior on color { ColorAnimation { duration: 200 } }

    implicitWidth: 16
    implicitHeight: 16

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "transparent"
            fillColor: glyph.color
            // Outer circle (8, 8) r 6 minus the circle (11, 5) r 5.
            PathSvg { path: "M 6.93 2.10 A 6 6 0 1 0 13.90 9.07 A 5 5 0 0 1 6.93 2.10 Z" }
        }
    }
}
