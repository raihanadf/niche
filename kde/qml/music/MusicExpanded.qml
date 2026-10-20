import QtQuick
import QtQuick.Effects
import org.kde.kirigami as Kirigami
import Niche

// niche's MusicExpandedView: cover, scrolling title and artist, bars; the
// seek bar between elapsed and remaining time; shuffle / previous /
// play-pause / next / output device; and, toggled by the output button, a
// volume row that makes the island 32 px taller.
Item {
    id: root

    // The island resets this when it closes (niche: output.isShowingVolume).
    property bool volumeShown: false

    readonly property real artSize: 56
    readonly property real waveWidth: 4 * 2.5 * 1.75
    readonly property real textWidth: width - artSize - waveWidth - 30

    // Song-change swap of title and artist (niche: .blurReplace(.downUp) with
    // Spring(duration: 0.38, bounce: 0.25)).
    property string oldTitle
    property string oldArtist
    property real swap: 1

    width: Metrics.contentWidth
    implicitHeight: Media.hasTrack ? 131 + (volumeShown ? 32 : 0) : 120
    height: implicitHeight

    function time(ms, negative) {
        const total = Math.max(0, Math.floor(ms / 1000));
        const seconds = total % 60;
        return (negative ? "-" : "") + Math.floor(total / 60) + ":" + (seconds < 10 ? "0" : "") + seconds;
    }

    Connections {
        target: Media

        // Fires before the new title/artist land, so these are the old ones.
        function onSongChangeTokenChanged() {
            root.oldTitle = Media.title;
            root.oldArtist = Media.artist;
            textSwap.restart();
        }
    }

    NumberAnimation {
        id: textSwap

        target: root
        property: "swap"
        from: 0
        to: 1
        duration: 380
        easing.type: Easing.OutBack
        easing.overshoot: 1.0
    }

    Text {
        visible: !Media.hasTrack
        width: root.width
        height: 120
        text: qsTr("Nothing playing")
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.pixelSize: 13
        font.weight: Font.Medium
        color: Qt.rgba(1, 1, 1, 0.5)
    }

    Item {
        id: content

        visible: Media.hasTrack
        width: root.width
        height: root.implicitHeight

        Item {
            id: header

            width: parent.width
            height: root.artSize

            MusicArtwork {
                width: root.artSize
                height: root.artSize
                radius: 12
                source: Media.artUrl
                token: Media.songChangeToken
                playing: Media.playing
            }

            Item {
                id: texts

                x: root.artSize + 14
                anchors.verticalCenter: parent.verticalCenter
                width: root.textWidth
                height: 17 + 1 + 16

                Item {
                    anchors.fill: parent
                    opacity: Math.min(1, root.swap)
                    scale: 0.85 + 0.15 * root.swap
                    transformOrigin: Item.Left
                    layer.enabled: root.swap < 1
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blurMax: 8
                        blur: Math.max(0, 1 - root.swap)
                    }

                    MusicMarquee {
                        width: parent.width
                        height: 17
                        text: Media.title
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: "white"
                    }

                    Text {
                        y: 18
                        width: parent.width
                        height: 16
                        text: Media.artist
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 13
                        color: Qt.rgba(1, 1, 1, 0.5)
                    }
                }

                Item {
                    anchors.fill: parent
                    visible: root.swap < 1
                    opacity: Math.max(0, 1 - root.swap)
                    scale: 1 - 0.15 * Math.min(1, root.swap)
                    transformOrigin: Item.Left
                    layer.enabled: visible
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blurMax: 8
                        blur: Math.min(1, root.swap)
                    }

                    Text {
                        width: parent.width
                        height: 17
                        text: root.oldTitle
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: "white"
                    }

                    Text {
                        y: 18
                        width: parent.width
                        height: 16
                        text: root.oldArtist
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        maximumLineCount: 1
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 13
                        color: Qt.rgba(1, 1, 1, 0.5)
                    }
                }
            }

            MusicBars {
                anchors.right: parent.right
                // On the artist line, so the feature switcher can take the
                // title line's corner on the same 18 px grid as the artwork.
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 9
                art: Media.artUrl
                seed: Media.title + "\n" + Media.artist
                barWidth: 2.5
                maxHeight: 14
            }
        }

        Item {
            id: seekRow

            y: header.height + 13
            width: parent.width
            height: 12

            Text {
                width: 32
                height: parent.height
                text: root.time(Media.position, false)
                horizontalAlignment: Text.AlignLeft
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: 11
                font.weight: Font.Medium
                font.letterSpacing: 0.1
                font.features: ({
                        "tnum": 1
                    })
                color: Qt.rgba(1, 1, 1, 0.5)
            }

            MusicSeekBar {
                x: 42
                width: parent.width - 84
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                art: Media.artUrl
                token: Media.songChangeToken
                fraction: Media.length > 0 ? Media.position / Media.length : 0
                onSeekRequested: target => {
                    if (Media.canSeek && Media.length > 0) {
                        Media.seek(Math.round(target * Media.length));
                    }
                }
            }

            Text {
                anchors.right: parent.right
                width: 32
                height: parent.height
                text: root.time(Media.length - Media.position, true)
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: 11
                font.weight: Font.Medium
                font.letterSpacing: 0.1
                font.features: ({
                        "tnum": 1
                    })
                color: Qt.rgba(1, 1, 1, 0.5)
            }
        }

        Row {
            id: controls

            readonly property real cell: width / 5

            x: -10
            y: seekRow.y + seekRow.height + 20
            width: parent.width + 20
            height: 30

            MusicControlButton {
                width: controls.cell
                height: controls.height
                enabled: Media.canShuffle
                onClicked: Media.toggleShuffle()

                MusicShuffleGlyph {
                    anchors.centerIn: parent
                    isOn: Media.shuffle
                }
            }

            MusicControlButton {
                width: controls.cell
                height: controls.height
                enabled: Media.canGoPrevious
                onClicked: {
                    backGlyph.play();
                    Media.previous();
                }

                MusicSkipGlyph {
                    id: backGlyph

                    anchors.centerIn: parent
                    forward: false
                }
            }

            MusicControlButton {
                width: controls.cell
                height: controls.height
                enabled: Media.canControl
                onClicked: Media.playPause()

                Kirigami.Icon {
                    id: playIcon

                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    source: Media.playing ? "media-playback-pause" : "media-playback-start"
                    color: "white"
                    isMask: true
                    roundToIconSize: false
                    // .contentTransition(.symbolEffect(.replace.downUp)) with
                    // Spring(duration: 0.35, bounce: 0.3)
                    onSourceChanged: playSwap.restart()

                    ParallelAnimation {
                        id: playSwap

                        NumberAnimation {
                            target: playIcon
                            property: "scale"
                            from: 0.4
                            to: 1
                            duration: 350
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.4
                        }
                        NumberAnimation {
                            target: playIcon
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: 180
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }

            MusicControlButton {
                width: controls.cell
                height: controls.height
                enabled: Media.canGoNext
                onClicked: {
                    nextGlyph.play();
                    Media.next();
                }

                MusicSkipGlyph {
                    id: nextGlyph

                    anchors.centerIn: parent
                    forward: true
                }
            }

            MusicControlButton {
                width: controls.cell
                height: controls.height
                active: root.volumeShown
                enabled: Output.canSetVolume
                onClicked: root.volumeShown = !root.volumeShown

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    source: Output.iconName
                    color: "white"
                    isMask: true
                    roundToIconSize: false
                    animated: true
                    opacity: root.volumeShown ? 1 : 0.5

                    Behavior on opacity {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.OutQuad
                        }
                    }
                }
            }
        }

        Item {
            id: volumeRow

            x: 10
            y: controls.y + controls.height + 20
            width: parent.width - 20
            height: 12
            opacity: root.volumeShown ? 1 : 0
            visible: opacity > 0.01
            layer.enabled: visible && opacity < 1
            layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: 8
                blur: 1 - volumeRow.opacity
            }

            // Spring(duration: 0.4, bounce: 0.2) with .blurReplace and an 8 px drop.
            Behavior on opacity {
                NumberAnimation {
                    duration: 300
                    easing.type: Easing.OutQuad
                }
            }
            transform: Translate {
                y: root.volumeShown ? 0 : -8

                Behavior on y {
                    NumberAnimation {
                        duration: 400
                        easing.type: Easing.OutBack
                        easing.overshoot: 1.0
                    }
                }
            }

            MouseArea {
                width: 20
                height: parent.height
                anchors.verticalCenter: parent.verticalCenter
                onClicked: Output.toggleMute()

                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 14
                    height: 14
                    source: Output.muted ? "audio-volume-muted-symbolic" : "audio-volume-low-symbolic"
                    color: "white"
                    isMask: true
                    roundToIconSize: false
                    animated: true
                    opacity: 0.5
                }
            }

            MusicVolumeSlider {
                x: 30
                width: parent.width - 60
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                level: Output.muted ? 0 : Output.volume
                onMoved: value => Output.setVolume(value)
            }

            Kirigami.Icon {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 20
                height: 14
                source: "audio-volume-high-symbolic"
                color: "white"
                isMask: true
                roundToIconSize: false
                opacity: 0.5
            }
        }
    }
}
