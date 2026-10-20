import QtQuick
import Niche

// niche's ClipboardView: two rows of five tiles plus a caption for the hovered
// (or keyboard-selected, else newest) item. Handles the keyboard itself while
// it has focus: 1–9 pick, arrows move the selection, Return picks,
// Delete/Backspace removes, Escape asks to close.
Item {
    id: root

    width: Metrics.contentWidth
    // Only as tall as the rows in use (one or two) plus the caption, so the
    // island keeps even padding below a single row.
    readonly property int rows: Math.max(1, Math.min(2, Math.ceil(Clipboard.count / columns)))
    height: rows * tileHeight + (rows - 1) * spacing + 8 + caption.height
    focus: true

    // niche's isKeyboard: number badges, selection ring and "⏎ paste" only
    // while the view drives the keyboard (opened by the shortcut). The island
    // may bind this explicitly; by default it follows keyboard focus.
    property bool keyboard: activeFocus

    signal picked(int index)
    signal closeRequested()

    readonly property int columns: 5
    readonly property real spacing: 6
    readonly property real tileHeight: 48
    readonly property real side: (width - spacing * (columns - 1)) / columns

    property Item hoveredCell: null
    property int revision: 0

    // Hovered tile, else the keyboard selection, else the newest item.
    readonly property Item focusCell: {
        root.revision
        const count = Clipboard.count
        if (root.hoveredCell)
            return root.hoveredCell
        if (count === 0)
            return null
        const selection = Clipboard.selection
        return grid.itemAtIndex(root.keyboard && selection >= 0 && selection < count ? selection : 0)
    }

    function bump() {
        revision++
    }

    function clamp(selection) {
        return Math.min(Math.max(selection, 0), Clipboard.count - 1)
    }

    onKeyboardChanged: Clipboard.selection = 0

    Connections {
        target: Clipboard
        function onRowsInserted() { Qt.callLater(root.bump) }
        function onRowsRemoved() { Qt.callLater(root.bump) }
        function onRowsMoved() { Qt.callLater(root.bump) }
        function onModelReset() { Qt.callLater(root.bump) }
    }

    Keys.onPressed: event => {
        event.accepted = true
        const count = Clipboard.count
        if (count === 0) {
            root.closeRequested()
            return
        }
        const current = Math.min(Clipboard.selection, count - 1)
        switch (event.key) {
        case Qt.Key_Escape:
            root.closeRequested()
            return
        case Qt.Key_Return:
        case Qt.Key_Enter:
            root.picked(current)
            return
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
            Clipboard.remove(current)
            return
        case Qt.Key_Left:
            Clipboard.selection = root.clamp(Clipboard.selection - 1)
            return
        case Qt.Key_Right:
            Clipboard.selection = root.clamp(Clipboard.selection + 1)
            return
        case Qt.Key_Up:
            Clipboard.selection = root.clamp(Clipboard.selection - root.columns)
            return
        case Qt.Key_Down:
            Clipboard.selection = root.clamp(Clipboard.selection + root.columns)
            return
        default: {
            const digit = parseInt(event.text)
            if (digit >= 1 && digit <= 9 && digit <= count)
                root.picked(digit - 1)
            return
        }
        }
    }

    Column {
        anchors.fill: parent
        spacing: 8

        GridView {
            id: grid
            // A full trailing gap per cell so exactly five columns fit.
            width: root.width + root.spacing
            height: root.rows * root.tileHeight + (root.rows - 1) * root.spacing
            cellWidth: root.side + root.spacing
            cellHeight: root.tileHeight + root.spacing
            interactive: false
            keyNavigationEnabled: false
            currentIndex: -1
            model: Clipboard.model

            // niche animates history changes with spring(response 0.4,
            // damping 0.85) and inserts with scale 0.6 + opacity.
            add: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "scale"; from: 0.6; to: 1; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.8 }
                    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 250; easing.type: Easing.OutCubic }
                }
            }
            remove: Transition {
                ParallelAnimation {
                    NumberAnimation { property: "scale"; to: 0.6; duration: 250; easing.type: Easing.OutCubic }
                    NumberAnimation { property: "opacity"; to: 0; duration: 200; easing.type: Easing.OutCubic }
                }
            }
            move: Transition {
                NumberAnimation { properties: "x,y"; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.8 }
            }
            displaced: Transition {
                NumberAnimation { properties: "x,y"; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.8 }
                NumberAnimation { properties: "scale,opacity"; to: 1; duration: 200 }
            }

            delegate: Item {
                id: cell

                required property int index
                required property string kind
                required property string preview
                required property string domain
                required property string label
                required property string itemId
                required property url image
                required property var color
                required property var date

                readonly property bool hovered: tile.hovered

                width: root.side
                height: root.tileHeight

                onHoveredChanged: {
                    if (hovered)
                        root.hoveredCell = cell
                    else if (root.hoveredCell === cell)
                        root.hoveredCell = null
                }
                GridView.onRemove: {
                    if (root.hoveredCell === cell)
                        root.hoveredCell = null
                    Qt.callLater(root.bump)
                }
                // itemAtIndex() only sees tiles once they exist; re-pick the
                // caption's item when one is created.
                Component.onCompleted: Qt.callLater(root.bump)

                ClipTile {
                    id: tile
                    anchors.fill: parent
                    kind: cell.kind
                    preview: cell.preview
                    domain: cell.domain
                    image: cell.image
                    swatch: cell.color !== undefined ? cell.color : "transparent"
                    number: root.keyboard && cell.index >= 0 && cell.index < 9 ? cell.index + 1 : 0
                    selected: root.keyboard && cell.index === Clipboard.selection
                    onClicked: root.picked(cell.index)
                    onDeleteClicked: Clipboard.remove(cell.index)
                }
            }
        }

        ClipCaption {
            id: caption
            width: root.width
            visible: root.focusCell !== null
            label: root.focusCell ? root.focusCell.label : ""
            date: root.focusCell ? root.focusCell.date : null
            keyboard: root.keyboard
            onClearClicked: Clipboard.clear()

            // niche swaps the caption with an easeOut(0.15) opacity transition.
            readonly property string shownId: root.focusCell ? root.focusCell.itemId : ""
            onShownIdChanged: fade.restart()

            NumberAnimation on opacity {
                id: fade
                running: false
                from: 0
                to: 1
                duration: 150
                easing.type: Easing.OutQuad
            }
        }
    }
}
