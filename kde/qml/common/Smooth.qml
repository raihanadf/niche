import QtQuick

// niche's spring(response: 0.4, dampingFraction: 0.95): settles without overshoot.
NumberAnimation {
    duration: 400
    easing.type: Easing.OutQuint
}
