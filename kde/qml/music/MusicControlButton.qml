import QtQuick

// niche's ControlButton: a 46×42 hit area whose rounded backdrop lights up on
// hover (white 9 %) or while its panel is open (13 %), squashing to 92 % while
// pressed. Content items center themselves in it.
Item {
    id: root

    property bool active: false
    default property alias content: holder.data

    signal clicked

    implicitHeight: 30
    opacity: enabled ? 1 : 0.35

    Item {
        id: body

        anchors.centerIn: parent
        width: 46
        height: 42
        scale: area.pressed ? 0.92 : 1

        // spring(response: 0.25, dampingFraction: 0.6)
        Behavior on scale {
            NumberAnimation {
                duration: 250
                easing.type: Easing.OutBack
                easing.overshoot: 2.2
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 13
            color: "white"
            opacity: root.active ? 0.13 : area.containsMouse ? 0.09 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                    easing.type: Easing.OutQuad
                }
            }
        }

        Item {
            id: holder

            anchors.fill: parent
        }
    }

    MouseArea {
        id: area

        anchors.fill: body
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
