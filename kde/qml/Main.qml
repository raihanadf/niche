import QtQuick
import Niche

// Transparent overlay surface (configured as a layer-shell overlay by Shell)
// sized for the largest island; only the island itself takes input.
Window {
    id: root
    width: Metrics.openWidth + 80
    height: 600
    visible: false
    color: "transparent"
    title: "niche"

    Island {
        anchors.fill: parent
    }

    // Preferences → the backends they control.
    Binding { target: Shell; property: "showInTray"; value: Settings.showInTray }
    Binding { target: Spectrum; property: "enabled"; value: Settings.liveVisualizer }
    Binding { target: Agents; property: "claudeEnabled"; value: Settings.showAgents && Settings.showClaude }
    Binding { target: Agents; property: "ompEnabled"; value: Settings.showAgents && Settings.showOmp }
    Binding { target: Clipboard; property: "enabled"; value: Settings.clipboardOn }
    Binding { target: Clipboard; property: "limit"; value: Settings.clipboardLimit }
    Binding { target: Clipboard; property: "shortcutEnabled"; value: Settings.clipboardOn && Settings.clipboardShortcut }
    Binding { target: Clipboard; property: "pastesOnPick"; value: Settings.pastesOnPick }
    Binding { target: Activities; property: "enabled"; value: Settings.activitiesOn }
    Binding { target: Activities; property: "disabledKinds"; value: Settings.disabledActivities }
}
