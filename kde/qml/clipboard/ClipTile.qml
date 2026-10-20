import QtQuick
import QtQuick.Effects
import org.kde.kirigami as Kirigami

// One history entry in ClipboardView (niche's ClipTile): image thumbnail,
// color swatch, file icon, link domain, or the first lines of text, with the
// keyboard number badge, selection ring and hover delete button.
Item {
    id: tile

    property string kind: "text"
    property string preview: ""
    property string domain: ""
    property url image: ""
    property color swatch: "transparent"
    // 1–9 while the keyboard drives the view, 0 hides the badge.
    property int number: 0
    property bool selected: false
    readonly property bool hovered: hover.hovered

    signal clicked()
    signal deleteClicked()

    HoverHandler {
        id: hover
    }

    Item {
        id: body
        anchors.fill: parent
        // niche: scaleEffect 1.05 with spring(response 0.3, damping 0.7).
        scale: tile.hovered || tile.selected ? 1.05 : 1
        Behavior on scale {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutBack
                easing.overshoot: 2
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 9
            color: Qt.rgba(1, 1, 1, 0.07)
        }

        Item {
            id: content
            anchors.fill: parent
            // Images fill the tile; round their corners like the background.
            layer.enabled: tile.kind === "image"
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: mask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1
            }

            Loader {
                anchors.fill: parent
                sourceComponent: {
                    switch (tile.kind) {
                    case "image": return imageContent
                    case "color": return colorContent
                    case "files": return filesContent
                    case "link": return linkContent
                    default: return textContent
                    }
                }
            }
        }

        Rectangle {
            id: mask
            anchors.fill: parent
            radius: 9
            visible: false
            layer.enabled: true
        }

        Rectangle {
            anchors.fill: parent
            radius: 9
            color: "transparent"
            border.color: Qt.rgba(1, 1, 1, tile.selected ? 0.85 : tile.hovered ? 0.3 : 0)
            border.width: tile.selected ? 1.5 : 1
        }

        MouseArea {
            anchors.fill: parent
            onClicked: tile.clicked()
        }

        // Keyboard number, bottom trailing.
        Rectangle {
            id: badge
            property int shown: 1
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 4
            width: 13
            height: 13
            radius: 6.5
            color: Qt.rgba(1, 1, 1, 0.9)
            opacity: tile.number > 0 ? 1 : 0
            scale: tile.number > 0 ? 1 : 0.5
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Connections {
                target: tile
                function onNumberChanged() {
                    if (tile.number > 0)
                        badge.shown = tile.number
                }
            }
            Component.onCompleted: if (tile.number > 0) shown = tile.number

            Text {
                anchors.centerIn: parent
                text: badge.shown
                color: "black"
                font.pixelSize: 9
                font.weight: Font.Bold
                font.features: { "tnum": 1 }
            }
        }

        // Delete button on hover, top trailing.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 3
            width: 14
            height: 14
            radius: 7
            color: Qt.rgba(0.25, 0.25, 0.25, 1)
            opacity: tile.hovered ? 1 : 0
            scale: tile.hovered ? 1 : 0.5
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Kirigami.Icon {
                anchors.centerIn: parent
                width: 8
                height: 8
                source: "window-close"
                color: "white"
                isMask: true
            }

            MouseArea {
                anchors.fill: parent
                enabled: tile.hovered
                onClicked: tile.deleteClicked()
            }
        }
    }

    Component {
        id: imageContent
        Image {
            source: tile.image
            fillMode: Image.PreserveAspectCrop
            cache: false
            smooth: true
        }
    }

    Component {
        id: colorContent
        Rectangle {
            radius: 9
            color: tile.swatch
        }
    }

    Component {
        id: filesContent
        Item {
            Image {
                anchors.fill: parent
                anchors.margins: 7
                source: tile.image
                fillMode: Image.PreserveAspectFit
                cache: false
                smooth: true
            }
        }
    }

    Component {
        id: linkContent
        Item {
            Column {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: tile.number > 0 ? -4 : 0
                width: parent.width - 12
                spacing: 4

                Kirigami.Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 12
                    height: 12
                    source: "link"
                    color: Qt.rgba(1, 1, 1, 0.85)
                    isMask: true
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: tile.domain
                    color: Qt.rgba(1, 1, 1, 0.85)
                    font.pixelSize: 9
                    font.weight: Font.Medium
                    elide: Text.ElideMiddle
                    maximumLineCount: 1
                }
            }
        }
    }

    Component {
        id: textContent
        Item {
            Text {
                anchors.fill: parent
                anchors.leftMargin: 7
                anchors.rightMargin: 7
                anchors.topMargin: 6
                anchors.bottomMargin: 6
                text: tile.preview
                textFormat: Text.PlainText
                color: Qt.rgba(1, 1, 1, 0.85)
                font.pixelSize: 10
                font.weight: Font.Medium
                wrapMode: Text.Wrap
                maximumLineCount: tile.number > 0 ? 2 : 3
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
                horizontalAlignment: Text.AlignLeft
                lineHeight: 0.95
            }
        }
    }
}
