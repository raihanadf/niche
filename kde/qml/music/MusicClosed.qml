import QtQuick
import Niche

// niche's MusicClosedView: the cover in the left slot and the dancing bars in
// the right one. Keeps showing the last track while the island animates away
// after the track is gone.
Item {
    id: root

    property url shownArt
    property string shownSeed

    width: Metrics.closedWidth
    height: Metrics.closedHeight

    function capture() {
        if (Media.hasTrack) {
            root.shownArt = Media.artUrl;
            root.shownSeed = Media.title + "\n" + Media.artist;
        }
    }

    Component.onCompleted: capture()

    Connections {
        target: Media

        function onHasTrackChanged() {
            root.capture();
        }
        function onArtUrlChanged() {
            root.capture();
        }
        function onTitleChanged() {
            root.capture();
        }
        function onArtistChanged() {
            root.capture();
        }
    }

    MusicArtwork {
        x: Metrics.capCenter - width / 2
        y: (root.height - height) / 2
        width: 24
        height: 24
        radius: 7
        source: root.shownArt
        token: Media.songChangeToken
        playing: Media.playing
    }

    MusicBars {
        x: root.width - Metrics.capCenter - width / 2
        anchors.verticalCenter: parent.verticalCenter
        art: root.shownArt
        seed: root.shownSeed
        barWidth: 2.4
        maxHeight: 12
    }
}
