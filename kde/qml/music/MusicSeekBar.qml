import QtQuick
import QtQuick.Effects

// niche's ProgressBar: a dim capsule filled with the blurred, saturated cover.
// The fill glides linearly between the once-a-second position ticks and
// springs quickly after a seek or a song change. Clicking seeks.
Item {
    id: root

    property url art
    property real fraction
    property int token
    property bool fast: false

    signal seekRequested(real fraction)

    implicitHeight: 6

    function hurry() {
        root.fast = true;
        settle.restart();
    }

    onTokenChanged: hurry()

    Timer {
        id: settle

        interval: 350
        onTriggered: root.fast = false
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Qt.rgba(1, 1, 1, 0.16)
    }

    MusicCover {
        id: cover

        anchors.fill: parent
        source: root.art
        animated: false
        visible: false
    }

    Item {
        id: fill

        anchors.fill: parent
        visible: false
        layer.enabled: true
        layer.smooth: true

        Rectangle {
            height: parent.height
            radius: height / 2
            color: "black"
            antialiasing: true
            width: parent.width * Math.max(0, Math.min(1, root.fraction))

            Behavior on width {
                NumberAnimation {
                    duration: root.fast ? 300 : 1000
                    easing.type: root.fast ? Easing.OutCubic : Easing.Linear
                }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: cover
        autoPaddingEnabled: false
        blurEnabled: true
        blurMax: 12
        blur: 0.5
        saturation: 0.6
        brightness: 0.15
        maskEnabled: true
        maskSource: fill
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    MouseArea {
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        onClicked: mouse => {
            root.hurry();
            root.seekRequested(Math.max(0, Math.min(1, mouse.x / root.width)));
        }
    }
}
