import QtQuick

// niche's AgentIndicator: 13 px glyph with the status dot on its bottom-right.
Item {
    id: root
    property string kind: "claude"
    property bool working: false

    width: 13
    height: 13

    AgentGlyph {
        anchors.fill: parent
        kind: root.kind
        size: 13
    }

    AgentStatusDot {
        working: root.working
        x: root.width - width + 4
        y: root.height - height + 2
    }
}
