import QtQuick
import QtQuick.Effects

// niche's MarqueeText: text wider than the view holds for 1.5 s, then scrolls
// left at 28 px/s with a second copy 28 px behind, looping seamlessly. While it
// scrolls, both edges fade out over 6 % of the width.
Item {
    id: root

    property string text
    property font font
    property color color: "white"

    readonly property real gap: 28
    readonly property real speed: 28
    readonly property int hold: 1500
    readonly property bool overflowing: label.implicitWidth > width
    readonly property real travel: label.implicitWidth + gap
    property real offset: 0

    implicitHeight: label.implicitHeight
    clip: true

    onTextChanged: {
        root.offset = 0;
        if (scroll.running) {
            scroll.restart();
        }
    }

    Item {
        id: content

        anchors.fill: parent
        visible: !root.overflowing

        Row {
            x: root.offset
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.gap

            Text {
                id: label

                text: root.text
                font: root.font
                color: root.color
                textFormat: Text.PlainText
            }

            Text {
                visible: root.overflowing
                text: root.text
                font: root.font
                color: root.color
                textFormat: Text.PlainText
            }
        }
    }

    Rectangle {
        id: fadeMask

        anchors.fill: parent
        visible: false
        layer.enabled: true
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop {
                position: 0
                color: "transparent"
            }
            GradientStop {
                position: 0.06
                color: "black"
            }
            GradientStop {
                position: 0.94
                color: "black"
            }
            GradientStop {
                position: 1
                color: "transparent"
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        visible: root.overflowing
        source: content
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: fadeMask
        maskThresholdMin: 0
        maskSpreadAtMin: 1.0
    }

    SequentialAnimation {
        id: scroll

        running: root.overflowing && root.visible
        loops: Animation.Infinite
        onRunningChanged: {
            if (!running) {
                root.offset = 0;
            }
        }

        PropertyAction {
            target: root
            property: "offset"
            value: 0
        }
        PauseAnimation {
            duration: root.hold
        }
        NumberAnimation {
            target: root
            property: "offset"
            from: 0
            to: -root.travel
            duration: Math.max(1, root.travel / root.speed * 1000)
            easing.type: Easing.Linear
        }
    }
}
