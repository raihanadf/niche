import QtQuick
import QtQuick.Layouts

// niche's AgentSessionRow: indicator, title, project, account badge and a
// Working / Paused capsule on a 22 px rounded hover background.
Item {
    id: root
    property string kind: "claude"
    property string title: ""
    property string project: ""
    property string account: ""
    property bool working: false
    signal clicked()

    readonly property color tint: working ? "#30d158" : "#ff9f0a"

    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 7
        color: Qt.rgba(1, 1, 1, hover.hovered ? 0.14 : 0.06)
        Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutQuad } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 9
        anchors.rightMargin: 9
        spacing: 8

        Item {
            Layout.preferredWidth: 16
            Layout.preferredHeight: 13
            AgentIndicator {
                anchors.centerIn: parent
                kind: root.kind
                working: root.working
            }
        }

        Text {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.maximumWidth: implicitWidth
            text: root.title.length > 0 ? root.title : root.project
            color: "white"
            font.pixelSize: 12
            font.weight: Font.Medium
            elide: Text.ElideRight
            maximumLineCount: 1
            textFormat: Text.PlainText
        }

        Text {
            Layout.minimumWidth: implicitWidth
            text: root.project
            color: Qt.rgba(1, 1, 1, 0.45)
            font.pixelSize: 10
            textFormat: Text.PlainText
        }

        Rectangle {
            visible: root.account.length > 0
            Layout.minimumWidth: accountText.implicitWidth + 10
            Layout.preferredWidth: accountText.implicitWidth + 10
            Layout.preferredHeight: accountText.implicitHeight + 2
            radius: height / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.25)

            Text {
                id: accountText
                anchors.centerIn: parent
                text: root.account
                color: Qt.rgba(1, 1, 1, 0.6)
                font.pixelSize: 9
                font.weight: Font.DemiBold
                textFormat: Text.PlainText
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.minimumWidth: 6
            Layout.preferredWidth: 6
        }

        Rectangle {
            Layout.minimumWidth: stateText.implicitWidth + 14
            Layout.preferredWidth: stateText.implicitWidth + 14
            Layout.preferredHeight: stateText.implicitHeight + 4
            radius: height / 2
            color: Qt.rgba(root.tint.r, root.tint.g, root.tint.b, 0.15)

            Text {
                id: stateText
                anchors.centerIn: parent
                text: root.working ? "Working" : "Paused"
                color: root.tint
                font.pixelSize: 10
                font.weight: Font.DemiBold
            }
        }
    }

    HoverHandler {
        id: hover
    }

    TapHandler {
        onTapped: root.clicked()
    }
}
