import QtQuick

// niche's StatusDot: 6 px green (working, pulsing) or orange (paused) dot with
// a 1.5 px black ring so it reads on top of a glyph.
Item {
    id: root
    property bool working: false

    width: 6
    height: 6

    Rectangle {
        id: dot
        anchors.centerIn: parent
        // A 1.5 px stroke centered on the 6 px circle's edge.
        width: 7.5
        height: 7.5
        radius: width / 2
        color: root.working ? "#30d158" : "#ff9f0a"
        border.width: 1.5
        border.color: "black"
        antialiasing: true

        SequentialAnimation on opacity {
            running: root.working && root.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running) dot.opacity = 1
            NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
        }
    }
}
