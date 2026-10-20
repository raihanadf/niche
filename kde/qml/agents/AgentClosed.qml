import QtQuick
import Niche

// niche's AgentClosedView. With idle art: the picture on the left, the agent
// indicators and the count on the right. Without: the agent glyphs on the
// left, one status dot and the count on the right. The count shows working
// sessions, or all sessions when none works.
Item {
    id: root
    property url art
    property rect artCrop: Qt.rect(0, 0, 1, 1)

    readonly property bool hasArt: art.toString().length > 0
    // niche's agentsRoom: two agent kinds need more room than one slot.
    readonly property bool needsRoom: Agents.kinds.length > 1
    readonly property real extraLeft: needsRoom && !hasArt ? 10 : 0
    readonly property real extraRight: needsRoom && hasArt ? 26 : 0

    // niche keeps the last non-empty sessions so the view does not blank out
    // while the island fades it away.
    property var shownKinds: Agents.kinds
    property var shownWorkingKinds: Agents.workingKinds
    property int shownCount: Agents.count
    property int shownWorking: Agents.workingCount

    function snapshot() {
        if (Agents.empty)
            return
        shownKinds = Agents.kinds
        shownWorkingKinds = Agents.workingKinds
        shownCount = Agents.count
        shownWorking = Agents.workingCount
    }

    Connections {
        target: Agents
        function onSessionsChanged() { root.snapshot() }
    }
    Component.onCompleted: snapshot()

    readonly property int countValue: shownWorking > 0 ? shownWorking : shownCount
    readonly property var allKinds: ["claude", "omp"]

    width: Metrics.closedWidth + extraLeft + extraRight
    height: Metrics.closedHeight

    // With art.
    Item {
        anchors.fill: parent
        visible: root.hasArt

        IdleArtView {
            x: Metrics.capCenter - width / 2
            y: (parent.height - height) / 2
            source: root.art
            crop: root.artCrop
            size: 24
            radius: 7
            playing: visible && root.visible
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Metrics.capInset
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 9
                add: AgentGlyphIn {}
                move: AgentGlyphMove {}

                Repeater {
                    model: root.allKinds
                    AgentIndicator {
                        required property string modelData
                        kind: modelData
                        visible: root.shownKinds.indexOf(modelData) >= 0
                        working: root.shownWorkingKinds.indexOf(modelData) >= 0
                    }
                }
            }

            AgentCount {
                anchors.verticalCenter: parent.verticalCenter
                value: root.countValue
            }
        }
    }

    // Without art.
    Item {
        anchors.fill: parent
        visible: !root.hasArt

        Row {
            // First glyph (14 px) centered in the leading end cap.
            x: Metrics.capCenter - 7
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            add: AgentGlyphIn {}
            move: AgentGlyphMove {}

            Repeater {
                model: root.allKinds
                AgentGlyph {
                    required property string modelData
                    kind: modelData
                    size: 14
                    visible: root.shownKinds.indexOf(modelData) >= 0
                }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: Metrics.capInset
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5

            AgentStatusDot {
                anchors.verticalCenter: parent.verticalCenter
                working: root.shownWorking > 0
            }

            AgentCount {
                anchors.verticalCenter: parent.verticalCenter
                value: root.countValue
            }
        }
    }
}
