import QtQuick
import QtQuick.Effects
import Niche

// niche's WaveformView: capsule bars cut out of the blurred, saturated cover.
// With the live visualizer they follow Spectrum.levels; otherwise every bar
// jumps to a pseudo-random height each 0.28 s, seeded by the song so every
// view of it dances alike. Paused bars rest at 2.5 px.
Item {
    id: root

    property url art
    property string seed
    property real barWidth: 2.4
    property real maxHeight: 12
    readonly property real minHeight: 2.5
    readonly property bool live: Spectrum.enabled
    readonly property bool playing: Media.playing
    readonly property int count: Spectrum.bands
    readonly property int tick: 280

    property int step: 0
    readonly property int seedHash: hash(seed)

    // Capture only while these bars are on screen and music plays.
    readonly property bool wantsCapture: visible && playing && live
    onWantsCaptureChanged: Spectrum.watch(root, wantsCapture)
    Component.onCompleted: {
        if (wantsCapture) {
            Spectrum.watch(root, true);
        }
    }
    Component.onDestruction: Spectrum.watch(root, false)

    width: count * barWidth * 1.75
    height: maxHeight

    function hash(text) {
        let h = 0x811c9dc5;
        for (let i = 0; i < text.length; ++i) {
            h ^= text.charCodeAt(i);
            h = Math.imul(h, 0x01000193);
        }
        return h >>> 0;
    }

    function simulated(bar) {
        let x = (Math.imul(root.step, 0x9e3779b1) ^ Math.imul(bar + 1, 0x85ebca77) ^ root.seedHash) >>> 0;
        x ^= x >>> 16;
        x = Math.imul(x, 0x7feb352d);
        x ^= x >>> 15;
        x = Math.imul(x, 0x846ca68b);
        x ^= x >>> 16;
        return 0.25 + 0.75 * ((x >>> 0) % 1000) / 1000;
    }

    function level(bar) {
        if (root.live) {
            const levels = Spectrum.levels;
            return bar < levels.length ? levels[bar] : 0;
        }
        return root.simulated(bar);
    }

    Timer {
        interval: root.tick
        repeat: true
        triggeredOnStart: true
        running: root.visible && root.playing && !root.live
        // Wall-clock steps, like niche's TimelineView, keep views in step.
        onTriggered: root.step = Math.floor(Date.now() / root.tick) % 1000000
    }

    MusicCover {
        id: cover

        anchors.fill: parent
        source: root.art
        animated: false
        visible: false
    }

    Item {
        id: mask

        anchors.fill: parent
        visible: false
        layer.enabled: true
        layer.smooth: true

        Row {
            anchors.centerIn: parent
            height: root.maxHeight
            spacing: root.barWidth * 0.75

            Repeater {
                model: root.count

                Rectangle {
                    required property int index

                    anchors.verticalCenter: parent.verticalCenter
                    width: root.barWidth
                    radius: width / 2
                    color: "black"
                    antialiasing: true
                    height: root.playing ? root.minHeight + root.level(index) * (root.maxHeight - root.minHeight) : root.minHeight

                    Behavior on height {
                        NumberAnimation {
                            duration: root.live && root.playing ? 1000 / 24 : root.tick
                            easing.type: root.live && root.playing ? Easing.OutQuad : Easing.OutCubic
                        }
                    }
                }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: cover
        autoPaddingEnabled: false
        blurEnabled: true
        blurMax: 8
        blur: 5 / 8
        saturation: 0.5
        brightness: 0.12
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
}
