import QtQuick

// niche's AgentGlyph: Claude's terracotta star of life, omp's blue serif π.
Item {
    id: root
    property string kind: "claude"
    property real size: 14

    width: size
    height: size

    // SF Symbol "staroflife.fill" at size * 0.82, bold: three rounded bars.
    Item {
        id: star
        visible: root.kind === "claude"
        anchors.centerIn: parent
        width: root.size * 0.82
        height: width

        Repeater {
            model: 3
            Rectangle {
                required property int index
                anchors.centerIn: parent
                width: star.width * 0.3
                height: star.height
                radius: width * 0.3
                antialiasing: true
                rotation: index * 60
                color: Qt.rgba(0.85, 0.47, 0.34, 1)
            }
        }
    }

    // π has no ascender or descender, so center its ink rather than the
    // text line box (which leaves it sitting low).
    Text {
        id: pi
        visible: root.kind === "omp"
        x: (root.width - width) / 2
        y: (root.height - ink.tightBoundingRect.height) / 2 - ink.tightBoundingRect.y - baselineOffset
        text: "π"
        color: Qt.rgba(0.55, 0.76, 1, 1)
        font.family: "serif"
        font.pixelSize: root.size + 3
        font.weight: Font.Black
        renderType: Text.QtRendering
    }
    TextMetrics {
        id: ink
        font: pi.font
        text: pi.text
    }
}
