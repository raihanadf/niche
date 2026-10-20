import QtQuick

// niche's Spring(duration: 0.5, bounce: 0.32): one soft overshoot.
NumberAnimation {
    duration: 500
    easing.type: Easing.OutBack
    easing.overshoot: 1.25
}
