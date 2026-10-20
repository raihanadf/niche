import QtQuick
import org.kde.kirigami as Kirigami

// niche's ShuffleGlyph: the shuffle mark lifts 3 px and a dot pops in under
// it while shuffle is on.
Item {
    id: root

    property bool isOn: false

    implicitWidth: 18
    implicitHeight: 24
    opacity: 0.5

    Kirigami.Icon {
        anchors.horizontalCenter: parent.horizontalCenter
        y: (root.height - height) / 2 + (root.isOn ? -3 : 0)
        width: 18
        height: 18
        source: "media-playlist-shuffle"
        color: "white"
        isMask: true
        roundToIconSize: false

        Behavior on y {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 1.2
            }
        }
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.height / 2 + 9 - height / 2
        width: 3.5
        height: 3.5
        radius: width / 2
        color: "white"
        scale: root.isOn ? 1 : 0.2
        opacity: root.isOn ? 1 : 0

        Behavior on scale {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 1.2
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutQuad
            }
        }
    }
}
