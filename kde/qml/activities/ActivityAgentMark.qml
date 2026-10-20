import QtQuick

// The agent marks of niche's AgentGlyph: Claude's six-armed star in clay
// orange, omp's serif π in light blue.
Item {
    id: mark

    property string kind: "claude"
    property real size: 13

    implicitWidth: size
    implicitHeight: size

    Item {
        anchors.centerIn: parent
        width: mark.size * 0.82
        height: width
        visible: mark.kind !== "omp"

        Repeater {
            model: 3

            Rectangle {
                required property int index
                anchors.centerIn: parent
                width: parent.width * 0.3
                height: parent.height
                radius: width * 0.4
                rotation: index * 60
                color: Qt.rgba(0.85, 0.47, 0.34, 1)
            }
        }
    }

    Text {
        anchors.centerIn: parent
        visible: mark.kind === "omp"
        text: "π"
        font.family: "serif"
        font.pixelSize: Math.round(mark.size + 3)
        font.weight: Font.Black
        color: Qt.rgba(0.55, 0.76, 1, 1)
    }
}
