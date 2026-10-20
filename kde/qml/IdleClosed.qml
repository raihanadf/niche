import QtQuick
import Niche

// niche's IdleClosedView: the island picture in the left slot.
Item {
    property alias source: art.source
    property alias crop: art.crop

    width: Metrics.closedWidth
    height: Metrics.closedHeight

    IdleArtView {
        id: art
        x: Metrics.capCenter - width / 2
        y: (parent.height - height) / 2
        size: 24
        radius: 7
    }
}
