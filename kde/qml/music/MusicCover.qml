import QtQuick
import org.kde.kirigami as Kirigami

// niche's ArtworkTile: the cover cropped to fill, or a grey tile with a note
// when there is none. A new source fades in over the old one once it has
// loaded (niche's 0.25 s ease-out for same-song artwork updates).
Item {
    id: root

    property url source
    // Fade between covers; off for tiles that only feed blur effects.
    property bool animated: true
    // Skip the fade for the next source change (a song swap animates itself).
    property bool instantNext: false

    property Image front: first
    property Image incoming: null
    property Image outgoing: null
    property bool completed: false

    function swap() {
        fade.stop();
        if (root.outgoing) {
            root.outgoing.opacity = 0;
            root.outgoing.source = "";
            root.outgoing = null;
        }
        const next = root.front === first ? second : first;
        next.opacity = 0;
        next.source = root.source;
        root.incoming = next;
        if (next.status !== Image.Loading) {
            root.reveal();
        }
    }

    function reveal() {
        const next = root.incoming;
        if (!next) {
            return;
        }
        root.incoming = null;
        const previous = root.front;
        root.front = next;
        next.z = 1;
        previous.z = 0;
        const instant = !root.animated || root.instantNext;
        root.instantNext = false;
        if (instant) {
            next.opacity = 1;
            previous.opacity = 0;
            previous.source = "";
            return;
        }
        root.outgoing = previous;
        if (next.status === Image.Ready) {
            fade.target = next;
            fade.from = 0;
            fade.to = 1;
        } else {
            // No picture (cleared or broken): fade the old one off the tile.
            next.opacity = 1;
            previous.z = 2;
            fade.target = previous;
            fade.from = 1;
            fade.to = 0;
        }
        fade.restart();
    }

    onSourceChanged: {
        if (root.completed) {
            root.swap();
        }
    }
    Component.onCompleted: {
        first.source = root.source;
        first.opacity = 1;
        root.completed = true;
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.22, 0.22, 0.22, 1)

        Kirigami.Icon {
            anchors.centerIn: parent
            width: 14
            height: width
            source: "music-note-16th"
            color: "white"
            isMask: true
            roundToIconSize: false
            opacity: 0.7
        }
    }

    Image {
        id: first

        anchors.fill: parent
        opacity: 0
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        // niche thumbnails artwork to 128 px; decode no larger.
        sourceSize: Qt.size(128, 128)
        onStatusChanged: {
            if (root.incoming === first && status !== Image.Loading) {
                root.reveal();
            }
        }
    }

    Image {
        id: second

        anchors.fill: parent
        opacity: 0
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        sourceSize: Qt.size(128, 128)
        onStatusChanged: {
            if (root.incoming === second && status !== Image.Loading) {
                root.reveal();
            }
        }
    }

    NumberAnimation {
        id: fade

        property: "opacity"
        duration: 250
        easing.type: Easing.OutQuad
        onFinished: {
            if (root.outgoing) {
                root.outgoing.opacity = 0;
                root.outgoing.source = "";
                root.outgoing.z = 0;
                root.outgoing = null;
            }
        }
    }
}
