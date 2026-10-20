import QtQuick

// A kind's glyph appearing in the closed view: .scale(0.5) + .opacity under
// spring(response: 0.4, dampingFraction: 0.85).
Transition {
    NumberAnimation { property: "scale"; from: 0.5; to: 1; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 0.8 }
    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 300; easing.type: Easing.OutCubic }
}
