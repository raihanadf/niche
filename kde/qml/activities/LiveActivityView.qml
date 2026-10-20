import QtQuick
import QtQuick.Effects
import org.kde.kirigami as Kirigami
import Niche

// niche's LiveActivityView: the current moment, glyph in the left slot and its
// value (label, level bar, ring, swatch…) in the right slot, which widens by
// Activities.extraWidth. Applies niche's ActivityFade (opacity, blur, scale)
// from Activities.showing and a blur-replace entrance whenever the kind changes.
Item {
    id: root

    readonly property real room: Activities.extraWidth
    readonly property bool batteryKind: shownKind === "lowBattery" || shownKind === "charging" || shownKind === "fullyCharged"

    readonly property color green: "#30D158"
    readonly property color red: "#FF453A"
    readonly property color focusTint: Qt.rgba(0.58, 0.5, 1, 1)
    readonly property color copyTint: Qt.rgba(0.45, 0.85, 0.8, 1)
    readonly property color labelColor: Qt.rgba(1, 1, 1, 0.85)

    // Kind currently laid out; changes recreate the slot contents like niche's .id(kind).
    property string shownKind: ""
    property bool shownOn: false

    // ActivityFade: in with niche's spring(0.4, bounce 0.25), out with easeOut 0.25.
    property real fade: Activities.showing ? 1 : 0
    Behavior on fade {
        NumberAnimation {
            duration: Activities.showing ? 400 : 250
            easing.type: Activities.showing ? Easing.OutBack : Easing.OutCubic
            easing.overshoot: 1.2
        }
    }
    // blurReplace entrance: spring(response 0.35, damping 0.9).
    property real enter: 1
    // symbolEffect(.replace) when Caps Lock / focus flip while shown.
    property real pop: 1

    implicitWidth: Metrics.closedWidth + Activities.extraWidth
    implicitHeight: Metrics.closedHeight

    function relayout() {
        const kind = Activities.kind;
        if (kind !== shownKind) {
            leading.active = false;
            trailing.active = false;
            shownKind = kind;
            leading.active = true;
            trailing.active = true;
            if (kind !== "")
                enterAnimation.restart();
        } else if (Activities.isOn !== shownOn && (kind === "capsLock" || kind === "focus")) {
            popAnimation.restart();
        }
        shownOn = Activities.isOn;
    }

    function leadingFor(kind) {
        switch (kind) {
        case "capsLock": return capsGlyph;
        case "focus": return moonGlyph;
        case "volume": return speakerGlyph;
        case "brightness": return sunGlyph;
        case "lowBattery":
        case "charging":
        case "fullyCharged": return batteryGlyph;
        case "headphones":
        case "headphonesBattery": return headphonesGlyph;
        case "agentDone": return agentGlyph;
        case "copied": return clipboardGlyph;
        default: return null;
        }
    }

    function trailingFor(kind) {
        switch (kind) {
        case "capsLock":
        case "focus": return onOffLabel;
        case "volume":
        case "brightness": return levelBar;
        case "lowBattery":
        case "charging":
        case "fullyCharged": return percentLabel;
        case "headphones": return headphonesValue;
        case "headphonesBattery": return lowRing;
        case "agentDone": return doneCheck;
        case "copied": return copiedValue;
        default: return null;
        }
    }

    Component.onCompleted: relayout()

    Connections {
        target: Activities
        function onActivityChanged() { root.relayout(); }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: Math.max(0, Math.min(1, root.fade)) * root.enter
        scale: (0.9 + 0.1 * root.fade) * (0.9 + 0.1 * root.enter)

        readonly property real blurAmount: Math.max(1 - root.fade, 1 - root.enter, 0)
        layer.enabled: blurAmount > 0.02
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 12
            blur: Math.min(content.blurAmount, 1) * 0.5
        }

        Item {
            width: Metrics.closedHeight
            height: parent.height

            Loader {
                id: leading
                anchors.centerIn: parent
                scale: root.pop
                sourceComponent: root.leadingFor(root.shownKind)
            }
        }

        Item {
            anchors.right: parent.right
            width: Metrics.closedHeight + root.room
            height: parent.height

            Loader {
                id: trailing
                anchors.verticalCenter: parent.verticalCenter
                x: root.room > 0 ? parent.width - width - Metrics.capInset : (parent.width - width) / 2
                sourceComponent: root.trailingFor(root.shownKind)
            }
        }
    }

    NumberAnimation {
        id: enterAnimation
        target: root
        property: "enter"
        from: 0
        to: 1
        duration: 350
        easing.type: Easing.OutCubic
    }

    NumberAnimation {
        id: popAnimation
        target: root
        property: "pop"
        from: 0.6
        to: 1
        duration: 400
        easing.type: Easing.OutBack
    }

    // MARK: Leading glyphs

    Component {
        id: capsGlyph
        CapsLockGlyph {
            lit: Activities.isOn
            color: Activities.isOn ? root.green : "white"
        }
    }

    Component {
        id: moonGlyph
        MoonGlyph {
            color: Activities.isOn ? root.focusTint : Qt.rgba(1, 1, 1, 0.5)
        }
    }

    Component {
        id: speakerGlyph
        SpeakerGlyph {
            level: Activities.isOn ? Activities.value : 1
            muted: !Activities.isOn
        }
    }

    Component {
        id: sunGlyph
        SunGlyph {
            level: Activities.value
        }
    }

    Component {
        id: batteryGlyph
        Kirigami.Icon {
            width: 20
            height: 20
            source: Activities.iconName
            isMask: true
            color: Activities.kind === "lowBattery" ? root.red : root.green
        }
    }

    Component {
        id: headphonesGlyph
        HeadphonesGlyph {
            iconName: Activities.iconName
            connected: Activities.kind !== "headphones" || Activities.isOn
        }
    }

    Component {
        id: agentGlyph
        ActivityAgentMark {
            kind: Activities.detail
            size: 13
        }
    }

    Component {
        id: clipboardGlyph
        Kirigami.Icon {
            width: 16
            height: 16
            source: "edit-paste-symbolic"
            isMask: true
            color: "white"
        }
    }

    // MARK: Trailing values

    Component {
        id: onOffLabel
        Text {
            text: Activities.text
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.features: ({ "tnum": 1 })
            color: root.labelColor
        }
    }

    Component {
        id: levelBar
        ActivityLevelBar {
            level: Activities.kind === "volume" && !Activities.isOn ? 0 : Activities.value
        }
    }

    Component {
        id: percentLabel
        Text {
            text: Activities.text
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.features: ({ "tnum": 1 })
            color: Activities.kind === "lowBattery" ? root.red : root.labelColor
        }
    }

    Component {
        id: headphonesValue
        Loader {
            sourceComponent: !Activities.isOn ? offLabel : Activities.value > 0 ? connectedRing : doneCheck
        }
    }

    Component {
        id: offLabel
        Text {
            text: qsTr("Off")
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: Qt.rgba(1, 1, 1, 0.5)
        }
    }

    Component {
        id: connectedRing
        BatteryRing {
            level: Activities.value
            low: false
        }
    }

    Component {
        id: lowRing
        BatteryRing {
            level: Activities.value
            low: true
        }
    }

    Component {
        id: doneCheck
        ActivityCheck {}
    }

    Component {
        id: copiedValue
        Loader {
            sourceComponent: Activities.hasColor ? swatch : Activities.image.toString() !== "" ? thumbnail : kindSymbol
        }
    }

    Component {
        id: swatch
        Rectangle {
            width: 14
            height: 14
            radius: 7
            color: Activities.color
            border.color: Qt.rgba(1, 1, 1, 0.3)
            border.width: 1
        }
    }

    Component {
        id: thumbnail
        Item {
            width: 18
            height: 18

            Image {
                id: thumbImage
                anchors.fill: parent
                source: Activities.image
                sourceSize: Qt.size(36, 36)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: false
            }

            Rectangle {
                id: thumbMask
                anchors.fill: parent
                radius: 4
                visible: false
                layer.enabled: true
            }

            MultiEffect {
                anchors.fill: parent
                source: thumbImage
                maskEnabled: true
                maskSource: thumbMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
        }
    }

    Component {
        id: kindSymbol
        Kirigami.Icon {
            width: 16
            height: 16
            source: Activities.iconName
            isMask: true
            color: root.copyTint
        }
    }
}
