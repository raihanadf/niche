import QtQuick

// Glyphs sliding over when a kind comes or goes in the closed view.
Transition {
    NumberAnimation { property: "x"; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.8 }
    NumberAnimation { property: "scale"; to: 1; duration: 200 }
    NumberAnimation { property: "opacity"; to: 1; duration: 200 }
}
