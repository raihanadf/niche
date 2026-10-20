import QtQuick
import Niche

// niche's ArtworkView: the cover shrinks to 82 % while paused, and on a song
// change the old cover squeezes away horizontally (0.1 s ease-in) before the
// new one springs open from 6 % width out of a 7 px blur.
Item {
    id: root

    property url source
    // Media.songChangeToken. It changes before Media.artUrl does, so `source`
    // still holds the outgoing cover inside onTokenChanged.
    property int token
    property bool playing
    property real radius: 7

    property real incoming: 1
    property real outgoing: 0
    property bool swapping: false
    property bool completed: false

    scale: root.playing ? 1 : 0.82
    Behavior on scale {
        Bouncy {}
    }

    Component.onCompleted: root.completed = true
    onTokenChanged: {
        if (!root.completed) {
            return;
        }
        old.source = root.source;
        current.snapNext();
        swap.restart();
    }

    MusicArtTile {
        id: old

        anchors.fill: parent
        radius: root.radius
        animated: false
        visible: root.swapping
        transform: Scale {
            origin.x: old.width / 2
            origin.y: old.height / 2
            xScale: 1 - 0.94 * root.outgoing
        }
    }

    MusicArtTile {
        id: current

        anchors.fill: parent
        radius: root.radius
        source: root.source
        opacity: root.swapping ? 0 : 1
        blur: 7 * Math.sqrt(Math.max(0, 1 - root.incoming))
        transform: Scale {
            origin.x: current.width / 2
            origin.y: current.height / 2
            xScale: Math.max(0, 0.06 + 0.94 * root.incoming)
        }
    }

    SequentialAnimation {
        id: swap

        PropertyAction {
            target: root
            property: "incoming"
            value: 0
        }
        PropertyAction {
            target: root
            property: "outgoing"
            value: 0
        }
        PropertyAction {
            target: root
            property: "swapping"
            value: true
        }
        NumberAnimation {
            target: root
            property: "outgoing"
            to: 1
            duration: 100
            easing.type: Easing.InQuad
        }
        PropertyAction {
            target: root
            property: "swapping"
            value: false
        }
        // Spring(duration: 0.4, bounce: 0.1): a slight overshoot.
        NumberAnimation {
            target: root
            property: "incoming"
            to: 1
            duration: 400
            easing.type: Easing.OutBack
            easing.overshoot: 0.6
        }
        ScriptAction {
            script: {
                old.source = "";
                current.clearSnap();
            }
        }
    }
}
