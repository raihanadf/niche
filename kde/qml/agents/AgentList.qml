import QtQuick
import Niche

// niche's AgentSessionList: 22 px rows, 4 apart; the first 4 are shown and a
// "+N more" / "Show less" toggle reveals the rest.
Item {
    id: root
    signal picked(string sessionId)

    // niche's showsAllAgents; reset whenever the list is hidden (island closes).
    property bool showsAll: false

    readonly property int visibleRows: 4
    readonly property real rowHeight: 22
    readonly property real spacing: 4
    readonly property real moreHeight: 12

    readonly property int rows: showsAll ? Agents.count : Math.min(Agents.count, visibleRows)
    readonly property bool hasMore: Agents.count > visibleRows
    readonly property real rowsHeight: rows * rowHeight + Math.max(rows - 1, 0) * spacing
    // niche's list part of agentsHeight, including the more row.
    readonly property real listHeight: rowsHeight + (hasMore ? spacing + moreHeight : 0)

    width: Metrics.contentWidth
    height: listHeight

    onVisibleChanged: if (!visible) showsAll = false

    ListView {
        id: list
        width: parent.width
        height: root.rowsHeight
        clip: true
        interactive: false
        spacing: root.spacing
        model: Agents.model
        boundsBehavior: Flickable.StopAtBounds

        delegate: AgentRow {
            required property var model

            width: ListView.view.width
            height: root.rowHeight
            kind: model.kind
            title: model.title
            project: model.project
            account: model.account
            working: model.working
            onClicked: root.picked(model.sessionId)
        }

        // niche: rows fade and slide in from the top, Spring(0.35, bounce 0.3).
        add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 350; easing.type: Easing.OutCubic }
            NumberAnimation { property: "y"; from: ViewTransition.destination.y - root.rowHeight; duration: 350; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }
        remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: 250; easing.type: Easing.OutCubic }
            NumberAnimation { property: "y"; to: ViewTransition.item.y - root.rowHeight; duration: 250; easing.type: Easing.OutCubic }
        }
        displaced: Transition {
            NumberAnimation { property: "y"; duration: 350; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
            NumberAnimation { property: "opacity"; to: 1; duration: 150 }
        }
    }

    // niche's MoreButton.
    Item {
        visible: root.hasMore
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.rowsHeight + root.spacing
        width: moreText.implicitWidth + 16
        height: root.moreHeight

        Text {
            id: moreText
            anchors.centerIn: parent
            text: root.showsAll ? "Show less" : "+" + (Agents.count - root.visibleRows) + " more"
            color: Qt.rgba(1, 1, 1, moreHover.hovered ? 0.8 : 0.45)
            font.pixelSize: 10
            font.weight: Font.Medium
            Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
        }

        HoverHandler {
            id: moreHover
        }

        TapHandler {
            onTapped: root.showsAll = !root.showsAll
        }
    }
}
