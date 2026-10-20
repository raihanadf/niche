import QtQuick
import QtQuick.Shapes

// SF Symbols' checkmark.circle.fill in green: the check is cut out of the disc.
Item {
    id: check

    property color color: "#30D158"

    implicitWidth: 14
    implicitHeight: 14

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: check.color
    }

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: "black"
            strokeWidth: 1.8
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: check.width * 0.3; startY: check.height * 0.52
            PathLine { x: check.width * 0.44; y: check.height * 0.66 }
            PathLine { x: check.width * 0.71; y: check.height * 0.36 }
        }
    }
}
