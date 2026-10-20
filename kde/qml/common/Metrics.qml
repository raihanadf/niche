pragma Singleton
import QtQuick

// Island geometry and palette shared by every view. Mirrors niche's
// hardwareNotch / slot / openSize constants, sized for a floating pill.
QtObject {
    // Closed pill: height, width of the empty middle, and the content slot on
    // each side (artwork / bars / glyphs live in the slots).
    readonly property real closedHeight: 32
    readonly property real baseWidth: 150
    readonly property real slot: 38
    readonly property real closedWidth: baseWidth + 2 * slot

    // Collapsed content sits in the capsule's round end caps: a leading or
    // trailing item is centered capCenter from its end (concentric with the
    // cap), and wider trailing items (bars, levels) end capInset from the edge.
    readonly property real capCenter: closedHeight / 2
    readonly property real capInset: 8

    // Open island.
    readonly property real openWidth: 345
    readonly property real openHeight: 175
    readonly property real padding: 18
    readonly property real openRadius: 30
    readonly property real contentWidth: openWidth - 2 * padding

    // Gap between the screen's top edge and the pill.
    readonly property real topGap: 6

    readonly property color background: "black"
    readonly property color musicTint: Qt.rgba(1, 0.42, 0.55, 1)
    readonly property color agentsTint: Qt.rgba(0.85, 0.6, 1, 1)
    readonly property color clipboardTint: Qt.rgba(0.45, 0.85, 0.8, 1)
    readonly property color secondaryText: Qt.rgba(1, 1, 1, 0.55)
    readonly property color control: Qt.rgba(1, 1, 1, 0.16)
}
