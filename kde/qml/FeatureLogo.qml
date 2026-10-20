import QtQuick
import org.kde.kirigami as Kirigami
import Niche

// Round badge for a feature in the switcher.
Rectangle {
    property string feature: "music"

    width: 22
    height: 22
    radius: 11
    color: Qt.rgba(0.16, 0.16, 0.16, 1)
    border.color: "black"
    border.width: 1.5

    Kirigami.Icon {
        anchors.centerIn: parent
        width: 12
        height: 12
        isMask: true
        color: feature === "agents" ? Metrics.agentsTint : feature === "clipboard" ? Metrics.clipboardTint : Metrics.musicTint
        source: feature === "agents" ? "tools-wizard-symbolic" : feature === "clipboard" ? "edit-paste-symbolic" : "music-note-16th-symbolic"
    }
}
