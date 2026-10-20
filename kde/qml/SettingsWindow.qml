import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Dialogs
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import Niche

// niche's SettingsView: one pane per feature; every feature and every live
// activity can be turned off on its own.
QQC2.ApplicationWindow {
    id: window
    title: "Settings"
    width: 780
    height: 480
    minimumWidth: 600
    minimumHeight: 400
    visible: true

    readonly property var panes: [
        { title: "General", icon: "configure" },
        { title: "Music", icon: "music-note-16th-symbolic" },
        { title: "Agents", icon: "tools-wizard-symbolic" },
        { title: "Clipboard", icon: "edit-paste-symbolic" },
        { title: "Live Activities", icon: "notifications" },
        { title: "Lock Screen", icon: "system-lock-screen" }
    ]

    component Footer: QQC2.Label {
        Layout.fillWidth: true
        Layout.maximumWidth: Kirigami.Units.gridUnit * 22
        wrapMode: Text.Wrap
        opacity: 0.7
        font: Kirigami.Theme.smallFont
    }

    component Pane: QQC2.ScrollView {
        default property alias content: form.data
        contentWidth: availableWidth
        Kirigami.FormLayout {
            id: form
            width: parent.width
        }
    }

    FileDialog {
        id: pictureDialog
        title: "Pick a picture or GIF for the island"
        nameFilters: ["Images (*.gif *.png *.jpg *.jpeg *.webp *.heic *.avif)"]
        onAccepted: {
            if (!Settings.setIdleImage(selectedFile))
                pictureError.open();
        }
    }

    Kirigami.PromptDialog {
        id: pictureError
        title: "niche couldn't open that picture."
        standardButtons: Kirigami.Dialog.Ok
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        QQC2.ScrollView {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 10
            Layout.fillHeight: true
            ListView {
                id: sidebar
                model: window.panes
                currentIndex: 0
                topMargin: Kirigami.Units.smallSpacing
                delegate: QQC2.ItemDelegate {
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    text: modelData.title
                    icon.name: modelData.icon
                    highlighted: ListView.isCurrentItem
                    onClicked: sidebar.currentIndex = index
                }
            }
        }

        Kirigami.Separator {
            Layout.fillHeight: true
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: Kirigami.Units.largeSpacing
            currentIndex: sidebar.currentIndex

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "System tray:"
                    text: "Show in system tray"
                    checked: Settings.showInTray
                    onToggled: Settings.showInTray = checked
                }
                QQC2.CheckBox {
                    text: "Open at login"
                    checked: Settings.openAtLogin
                    onToggled: Settings.openAtLogin = checked
                }
                Footer {
                    text: "Right-click the island to open these settings when the tray icon is hidden."
                }

                Item { Kirigami.FormData.isSection: true }

                RowLayout {
                    Kirigami.FormData.label: "Island picture:"
                    spacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: Settings.builtInArt
                        QQC2.AbstractButton {
                            required property string modelData
                            implicitWidth: 36
                            implicitHeight: 36
                            hoverEnabled: true
                            QQC2.ToolTip.text: modelData.replace(/-/g, " ")
                            QQC2.ToolTip.visible: hovered
                            onClicked: Settings.setIdleBuiltIn(modelData)
                            contentItem: Item {}
                            background: Rectangle {
                                radius: 9
                                color: "black"
                                border.width: 2
                                border.color: Settings.idleBuiltIn === modelData ? Kirigami.Theme.highlightColor : "transparent"
                                IdleArtView {
                                    anchors.centerIn: parent
                                    source: Settings.builtInUrl(modelData)
                                    crop: Settings.cropFor(Settings.builtInUrl(modelData))
                                    size: 26
                                    radius: 6
                                }
                            }
                        }
                    }
                }
                RowLayout {
                    Kirigami.FormData.label: "Your own:"
                    spacing: Kirigami.Units.largeSpacing
                    Rectangle {
                        visible: Settings.idleArt.toString() !== "" && Settings.idleBuiltIn === ""
                        implicitWidth: 34
                        implicitHeight: 34
                        radius: 8
                        color: "black"
                        IdleArtView {
                            anchors.centerIn: parent
                            source: Settings.idleArt
                            crop: Settings.idleArtCrop
                            size: 28
                            radius: 7
                        }
                    }
                    QQC2.Button {
                        text: "Choose…"
                        onClicked: pictureDialog.open()
                    }
                    QQC2.Button {
                        visible: Settings.idleArt.toString() !== ""
                        text: "Remove"
                        onClicked: Settings.clearIdleImage()
                    }
                }
                Footer {
                    text: "Pick one of niche's own, or choose a picture or GIF. It sits on the left of the island when no music is showing, next to your agents if any are running. Music and live activities take its place. Best at 64 × 64 pixels or larger, square, with a transparent background. Empty space around the art is trimmed."
                }

                Item { Kirigami.FormData.isSection: true }

                QQC2.Button {
                    text: "Quit niche"
                    icon.name: "application-exit"
                    onClicked: Shell.quit()
                }
            }

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "Visualizer:"
                    text: "Live visualizer"
                    checked: Settings.liveVisualizer
                    onToggled: Settings.liveVisualizer = checked
                }
                Footer {
                    text: "Live bars follow what your speakers are playing, read from the output's monitor through PipeWire. With this off the bars move on their own and nothing is captured."
                }
            }

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "Sessions:"
                    text: "Show agent sessions"
                    checked: Settings.showAgents
                    onToggled: Settings.showAgents = checked
                }
                Footer {
                    text: "Running agent sessions get a mark in the open island and their own mode in the feature switcher. Only live sessions are listed."
                }
                QQC2.CheckBox {
                    Kirigami.FormData.label: "Agents:"
                    text: "Claude Code"
                    enabled: Settings.showAgents
                    checked: Settings.showClaude
                    onToggled: Settings.showClaude = checked
                }
                QQC2.CheckBox {
                    text: "omp"
                    enabled: Settings.showAgents
                    checked: Settings.showOmp
                    onToggled: Settings.showOmp = checked
                }
                Footer {
                    Kirigami.FormData.label: "Open session on click:"
                    text: "Clicking a session switches tmux to its pane and brings the terminal window forward. In Konsole and kitty the right tab is picked too."
                }
            }

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "History:"
                    text: "Keep clipboard history"
                    checked: Settings.clipboardOn
                    onToggled: Settings.clipboardOn = checked
                }
                QQC2.SpinBox {
                    Kirigami.FormData.label: "Remember:"
                    enabled: Settings.clipboardOn
                    from: 3
                    to: Clipboard.maxLimit
                    value: Settings.clipboardLimit
                    textFromValue: value => value + " items"
                    valueFromText: text => parseInt(text)
                    onValueModified: Settings.clipboardLimit = value
                }
                Footer {
                    text: "Copies stay on this computer, in memory only, and are gone when niche quits. Passwords copied from password managers are skipped."
                }

                Item { Kirigami.FormData.isSection: true }

                QQC2.CheckBox {
                    Kirigami.FormData.label: "Shortcut:"
                    text: "Open with Ctrl+Alt+V"
                    enabled: Settings.clipboardOn
                    checked: Settings.clipboardShortcut
                    onToggled: Settings.clipboardShortcut = checked
                }
                QQC2.CheckBox {
                    text: "Paste when picking an item"
                    enabled: Settings.clipboardOn
                    checked: Settings.pastesOnPick
                    onToggled: Settings.pastesOnPick = checked
                }
                QQC2.Label {
                    Kirigami.FormData.label: "Pasting:"
                    text: Clipboard.canPaste ? "Allowed" : "Not allowed"
                    color: Clipboard.canPaste ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.neutralTextColor
                }
                Footer {
                    text: "Ctrl+Alt+V opens the clipboard from anywhere: press 1 to 9, or move with the arrows and press Return. With nothing copied yet the island just gives a little bounce. The shortcut can be changed in System Settings → Shortcuts. Pasting straight into the app you were typing in needs KWin's fake-input permission, which niche gets when it runs from its installed desktop entry; without it, the item is copied and you press Ctrl+V."
                }

                Item { Kirigami.FormData.isSection: true }

                QQC2.Button {
                    text: "Clear history"
                    icon.name: "edit-clear-history"
                    enabled: Clipboard.count > 0
                    onClicked: Clipboard.clear()
                }
            }

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "Popups:"
                    text: "Live activities"
                    checked: Settings.activitiesOn
                    onToggled: Settings.activitiesOn = checked
                }
                Footer {
                    text: "Short popups in the closed island when something changes, then it goes back to what it was showing."
                }

                Item { Kirigami.FormData.isSection: true }

                Repeater {
                    model: Activities.kinds()
                    QQC2.CheckBox {
                        required property var modelData
                        required property int index
                        Kirigami.FormData.label: index === 0 ? "Show:" : ""
                        text: modelData.title
                        enabled: Settings.activitiesOn
                        checked: Settings.disabledActivities.indexOf(modelData.kind) < 0
                        onToggled: Settings.toggleActivity(modelData.kind, checked)
                    }
                }

                Item { Kirigami.FormData.isSection: true }

                QQC2.CheckBox {
                    Kirigami.FormData.label: "Plasma popups:"
                    text: "Replace Plasma's volume and brightness popups"
                    enabled: Settings.activitiesOn
                    checked: Activities.replacesSystemHUD
                    onToggled: Activities.replacesSystemHUD = checked
                }
                QQC2.Button {
                    text: "Restart Plasma shell now"
                    visible: Activities.shellRestartPending
                    icon.name: "view-refresh"
                    onClicked: Activities.restartPlasmaShell()
                }
                Footer {
                    text: "This turns Plasma's on-screen display off, so only the island shows volume and brightness changes (Plasma's keyboard layout and toggle popups go with it). It takes effect when the Plasma shell restarts."
                }
            }

            Pane {
                QQC2.CheckBox {
                    Kirigami.FormData.label: "Lock:"
                    text: "Show lock indicator"
                    checked: Settings.showLockIndicator
                    onToggled: Settings.showLockIndicator = checked
                }
                Footer {
                    text: "A padlock sits in the island when you lock the screen and springs open when you're back. Plasma's lock screen covers every other window, so you see it open as you unlock."
                }
                QQC2.Label {
                    Kirigami.FormData.label: "Version:"
                    text: Settings.version
                }
            }
        }
    }
}
