import QtQuick
import QtQuick.Effects
import Niche

// The island: niche's LabState + NicheView. Decides what the pill shows,
// grows it on hover, and routes every feature view into place.
Item {
    id: island

    // ---- state (LabState / NotchController) ----
    property bool expanded: false
    property bool collapsing: false
    property bool springy: false // bouncy resize while opening or gaining content
    property string selectedFeature: ""
    property string peekFeature: ""
    property string closedFeature: "music"
    property string lockState: "none" // none | locked | unlocking
    property bool lockShown: false
    property bool lifted: false
    property bool pressed: false
    property real stretch: 0
    property string hop: ""

    readonly property var allFeatures: ["music", "agents", "clipboard"]
    readonly property bool hasArt: Settings.idleArt.toString() !== ""
    readonly property bool hasActivity: Activities.kind !== ""

    readonly property var activeFeatures: {
        const live = [];
        if (Media.hasTrack)
            live.push("music");
        if (!Agents.empty)
            live.push("agents");
        return live;
    }
    readonly property string shownFeature: selectedFeature !== "" && activeFeatures.indexOf(selectedFeature) >= 0
        ? selectedFeature : (activeFeatures.length > 0 ? activeFeatures[0] : "")
    readonly property string openFeature: {
        if (peekFeature === "clipboard" && Clipboard.count > 0)
            return "clipboard";
        if (peekFeature !== "" && activeFeatures.indexOf(peekFeature) >= 0)
            return peekFeature;
        return shownFeature;
    }
    readonly property var upcomingFeatures: {
        const live = activeFeatures;
        const index = live.indexOf(openFeature);
        if (index < 0)
            return [];
        const next = [];
        for (let i = 1; i < live.length; ++i)
            next.push(live[(index + i) % live.length]);
        return next;
    }

    readonly property bool hasClosedContent: shownFeature !== "" || hasArt || lockState !== "none" || hasActivity
    readonly property bool hasOpenableContent: Media.hasTrack || !Agents.empty || peekFeature === "clipboard"

    // What the closed pill is showing right now.
    readonly property bool lockVisible: !expanded && lockState !== "none"
    readonly property bool activityVisible: !expanded && lockState === "none" && hasActivity
    readonly property bool closedVisible: !expanded && lockState === "none" && !hasActivity && hasClosedContent

    // ---- geometry (currentSize / rooms) ----
    // The open island's top row holds the live activity or the feature
    // switcher. It sits so the 22 px switcher lands on the 18 px content grid
    // (18 from the top and right, like the artwork and seek row).
    readonly property real topRowY: Metrics.padding - (Metrics.closedHeight - 22) / 2
    // The top row's live activity sits like its horizontal inset: glyph box
    // 18 px from the top (padding - capInset for the view), content 6 px below.
    readonly property real activityTop: Metrics.padding - Metrics.capInset
    readonly property real activityRoom: expanded && hasActivity && openFeature !== "agents" && openFeature !== "clipboard"
        ? activityTop + Metrics.closedHeight + 6 - Metrics.padding : 0
    readonly property real volumeRoom: expanded && openFeature === "music" && Media.hasTrack
        && expandedLoader.item && expandedLoader.item.volumeShown === true ? 32 : 0
    readonly property bool earsShown: upcomingFeatures.length > 0 && openFeature !== ""
    readonly property bool topRowShown: hasActivity || earsShown
    // Even padding around the open content: 18 px on every side (music's
    // controls row carries 6 px of its own below the icons). Lists and tiles
    // only drop below the top row when it has something in it.
    readonly property real contentTop: openFeature === "music" ? Metrics.padding + activityRoom
        : topRowShown ? topRowY + Metrics.closedHeight + 2 : Metrics.padding
    readonly property real contentBottom: openFeature === "music" ? Metrics.padding - 6 : Metrics.padding
    readonly property real contentHeight: !expandedLoader.item ? Metrics.openHeight - 2 * Metrics.padding
        : expandedLoader.item.listHeight !== undefined ? expandedLoader.item.listHeight : expandedLoader.item.height
    readonly property bool agentsRoomApplies: !expanded && lockState === "none" && !hasActivity && shownFeature === "agents"
        && closedLoader.item && closedLoader.item.extraLeft !== undefined
    readonly property real agentsLeft: agentsRoomApplies ? closedLoader.item.extraLeft : 0
    readonly property real agentsRight: agentsRoomApplies ? closedLoader.item.extraRight : 0
    readonly property real levelRoom: !expanded && lockState === "none" && hasActivity ? Activities.extraWidth : 0
    readonly property real closedOffset: expanded ? 0 : (agentsRight + levelRoom - agentsLeft) / 2

    readonly property real targetWidth: expanded ? Metrics.openWidth
        : Metrics.baseWidth + (hasClosedContent ? 2 * Metrics.slot : 0) + agentsLeft + agentsRight + levelRoom
    readonly property real targetHeight: !expanded ? Metrics.closedHeight : contentTop + contentHeight + contentBottom

    // ---- behavior ----
    function setOpen(open) {
        if (open === expanded && !collapsing)
            return;
        if (open) {
            springy = true;
            collapsing = false;
            pressed = false;
            expanded = true;
        } else {
            springy = hasClosedContent;
            collapsing = true;
            expanded = false;
            collapseDone.restart();
            peekFeature = "";
            Shell.keyboardGrab = false;
            Shell.relieveMemory();
        }
    }

    function hover(inside) {
        if (!hasOpenableContent && lockState === "none" && !expanded) {
            if (inside)
                pulse();
            return;
        }
        setOpen(inside && lockState === "none");
    }

    function pulse() {
        lifted = true;
        pulseDown.restart();
    }

    function switchFeature() {
        if (upcomingFeatures.length === 0)
            return;
        const next = upcomingFeatures[0];
        peekFeature = "";
        selectedFeature = next;
    }

    function toggleClipboard() {
        if (lockState !== "none")
            return;
        // Nothing copied yet (history is in memory only): acknowledge the
        // press with the empty-hover bounce instead of doing nothing.
        if (Clipboard.count === 0) {
            if (!expanded)
                pulse();
            return;
        }
        if (expanded && openFeature === "clipboard") {
            setOpen(false);
            return;
        }
        peekFeature = "clipboard";
        setOpen(true);
        Shell.keyboardGrab = true;
    }

    function pick(index) {
        const paste = Clipboard.pastesOnPick && Clipboard.canPaste;
        const item = Clipboard.item(index);
        setOpen(false);
        Clipboard.pick(index);
        if (!paste && item)
            Activities.copied(item.kind, item.text, item.image, item.color);
    }

    function screenLocked() {
        unlockLater.stop();
        lockFade.stop();
        lockClear.stop();
        if (!Settings.showLockIndicator)
            return;
        setOpen(false);
        springy = true;
        lockState = "locked";
        lockShown = true;
    }

    function screenUnlocked() {
        if (lockState !== "locked")
            return;
        // KWin fades the lock screen out first; unlatch once we're visible.
        unlockLater.restart();
    }

    Timer { id: collapseDone; interval: 400; onTriggered: island.collapsing = false }
    Timer { id: pulseDown; interval: 180; onTriggered: island.lifted = false }
    Timer { id: hopDone; interval: 160; onTriggered: island.hop = "" }
    Timer {
        id: unlockLater
        interval: 350
        onTriggered: {
            island.lockState = "unlocking";
            lockFade.restart();
        }
    }
    Timer { id: lockFade; interval: 1100; onTriggered: { island.lockShown = false; lockClear.restart(); } }
    Timer { id: lockClear; interval: 300; onTriggered: { island.springy = false; island.lockState = "none"; } }

    onHasOpenableContentChanged: if (!hasOpenableContent) setOpen(false)
    onShownFeatureChanged: if (shownFeature !== "") closedFeature = shownFeature
    onHasClosedContentChanged: if (!expanded) springy = hasClosedContent
    Component.onCompleted: if (shownFeature !== "") closedFeature = shownFeature

    Connections {
        target: Media
        function onPlayingChanged() {
            if (Media.playing)
                island.selectedFeature = "music";
        }
    }
    Connections {
        target: Clipboard
        function onHotKey() { island.toggleClipboard(); }
        function onCopied(kind, text, image, color) {
            if (!(island.expanded && island.openFeature === "clipboard"))
                Activities.copied(kind, text, image, color);
        }
    }
    Connections {
        target: Agents
        function onFinished(kind) { Activities.agentFinished(kind); }
    }
    Connections {
        target: Shell
        function onLockedChanged() { Shell.locked ? island.screenLocked() : island.screenUnlocked(); }
        function onKeyboardGrabChanged() {
            if (island.expanded && island.openFeature === "clipboard") {
                if (!Shell.keyboardGrab)
                    island.setOpen(false);
                else if (expandedLoader.item)
                    expandedLoader.item.forceActiveFocus();
            }
        }
    }

    Binding { target: Activities; property: "suppressVolume"; value: island.volumeRoom > 0 }

    // ---- input ----
    // Pointer input only lands on the pill (plus a small margin and the gap
    // above it); the rest of the surface clicks through.
    readonly property rect inputRect: {
        const targetX = (width - targetWidth) / 2 + closedOffset;
        const left = Math.min(shape.x, targetX) - 8;
        const right = Math.max(shape.x + shape.width, targetX + targetWidth) + 8;
        const bottom = Math.max(shape.y + shape.height, Metrics.topGap + targetHeight) + 8;
        return Qt.rect(left, 0, right - left, bottom);
    }
    onInputRectChanged: Shell.setInputRect(inputRect)

    HoverHandler {
        id: hoverHandler
        onHoveredChanged: island.hover(hovered)
    }

    // ---- the pill ----
    Item {
        id: shape
        // Grow around a fixed center: only the size and the closed-state offset
        // animate. (Animating x itself lagged behind the animated width, which
        // pushed the opening island right and past the surface edge.)
        property real offset: island.closedOffset
        Behavior on offset { NumberAnimation { duration: island.springy ? 500 : 380; easing.type: island.springy ? Easing.OutBack : Easing.OutQuint; easing.overshoot: 1.25 } }
        x: (island.width - width) / 2 + offset
        y: Metrics.topGap
        width: island.targetWidth
        height: island.targetHeight

        Behavior on width { NumberAnimation { duration: island.springy ? 500 : 380; easing.type: island.springy ? Easing.OutBack : Easing.OutQuint; easing.overshoot: 1.25 } }
        Behavior on height { NumberAnimation { duration: island.springy ? 500 : 380; easing.type: island.springy ? Easing.OutBack : Easing.OutQuint; easing.overshoot: 1.25 } }

        // NotchSquashModifier: lift on an empty hover, squash on press, stretch on drag.
        property real liftX: island.lifted ? 1.06 : 1
        property real liftY: island.lifted ? 1.12 : 1
        property real pressX: island.pressed ? 0.97 : 1
        property real pressY: island.pressed ? 0.92 : 1
        property real drag: 1 - island.stretch * 0.09
        Behavior on liftX { NumberAnimation { duration: island.lifted ? 280 : 420; easing.type: island.lifted ? Easing.OutBack : Easing.OutQuint; easing.overshoot: 2.2 } }
        Behavior on liftY { NumberAnimation { duration: island.lifted ? 280 : 420; easing.type: island.lifted ? Easing.OutBack : Easing.OutQuint; easing.overshoot: 2.2 } }
        Behavior on pressX { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on pressY { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        Behavior on drag { enabled: island.stretch === 0; NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        transform: Scale {
            origin.x: shape.width / 2
            origin.y: 0
            xScale: shape.liftX * shape.pressX
            yScale: shape.liftY * shape.pressY * shape.drag
        }

        Rectangle {
            id: body
            anchors.fill: parent
            // Pure function of the current (animated) height: a capsule while
            // short, the open radius once tall. No animation of its own; one
            // used to lag behind the height and give different corners for the
            // same size depending on direction.
            radius: Math.min(height / 2, Metrics.openRadius)
            color: Metrics.background

            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: "black"
                shadowOpacity: island.expanded ? 0.55 : 0.3
                shadowBlur: island.expanded ? 1.0 : 0.5
                shadowVerticalOffset: 4
                Behavior on shadowOpacity { NumberAnimation { duration: 350 } }
            }
        }

        // Faint rim light on the open island, brighter at the bottom.
        Rectangle {
            anchors.fill: parent
            radius: body.radius
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.14)
            opacity: island.expanded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutQuad } }
        }

        // Press, drag-stretch and right-click (settings). Sits under the
        // content so its own buttons win.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property real startY: 0
            onPressed: mouse => {
                if (mouse.button === Qt.RightButton) {
                    Shell.openSettings();
                    return;
                }
                startY = mouse.y;
                if (!island.expanded)
                    island.pressed = true;
            }
            onPositionChanged: mouse => {
                if (island.expanded || !(mouse.buttons & Qt.LeftButton))
                    return;
                const dy = mouse.y - startY;
                island.pressed = Math.abs(dy) < 4;
                island.stretch = Math.max(-1, Math.min(1, -dy / 60));
            }
            onReleased: {
                island.pressed = false;
                island.stretch = 0;
            }
            onCanceled: {
                island.pressed = false;
                island.stretch = 0;
            }
        }

        Item {
            id: content
            anchors.fill: parent
            clip: true

            // Closed: lock, live activity, or the feature's closed view.
            LockIndicator {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Metrics.closedWidth
                height: Metrics.closedHeight
                visible: island.lockVisible
                lockState: island.lockState
                shown: island.lockShown
            }

            LiveActivityView {
                id: closedActivity
                anchors.horizontalCenter: parent.horizontalCenter
                width: Metrics.closedWidth + Activities.extraWidth
                height: Metrics.closedHeight
                visible: opacity > 0
                opacity: island.activityVisible ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: island.activityVisible ? 250 : 100 } }
            }

            Loader {
                id: closedLoader
                anchors.horizontalCenter: parent.horizontalCenter
                width: Metrics.closedWidth + island.agentsLeft + island.agentsRight
                height: Metrics.closedHeight
                sourceComponent: island.shownFeature === "" && island.hasArt ? idleClosed
                    : island.closedFeature === "agents" ? agentsClosed : musicClosed
                visible: opacity > 0
                opacity: 0
                scale: 0.75
                states: State {
                    name: "shown"
                    when: island.closedVisible
                    PropertyChanges { closedLoader.opacity: 1; closedLoader.scale: 1 }
                }
                transitions: [
                    Transition {
                        to: "shown"
                        SequentialAnimation {
                            PauseAnimation { duration: island.collapsing ? 250 : 50 }
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; duration: 200; easing.type: Easing.OutQuad }
                                NumberAnimation { property: "scale"; duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
                            }
                        }
                    },
                    Transition {
                        from: "shown"
                        ParallelAnimation {
                            NumberAnimation { property: "opacity"; duration: 100; easing.type: Easing.OutQuad }
                            NumberAnimation { property: "scale"; duration: 450; easing.type: Easing.OutQuint }
                        }
                    }
                ]
            }

            // Open: the feature view plus a top row with the live activity or
            // the feature switcher.
            Item {
                id: expandedLayer
                width: Metrics.openWidth
                height: parent.height
                anchors.horizontalCenter: parent.horizontalCenter
                visible: opacity > 0
                opacity: 0
                states: State {
                    name: "open"
                    when: island.expanded
                    PropertyChanges { expandedLayer.opacity: 1 }
                }
                transitions: [
                    Transition {
                        to: "open"
                        SequentialAnimation {
                            PauseAnimation { duration: 120 }
                            NumberAnimation { property: "opacity"; duration: 200; easing.type: Easing.OutQuad }
                        }
                    },
                    Transition {
                        from: "open"
                        NumberAnimation { property: "opacity"; duration: 100; easing.type: Easing.OutQuad }
                    }
                ]

                Loader {
                    id: expandedLoader
                    x: Metrics.padding
                    y: island.contentTop
                    width: Metrics.contentWidth
                    active: island.expanded || island.collapsing
                    sourceComponent: island.openFeature === "agents" ? agentList
                        : island.openFeature === "clipboard" ? clipboardView
                        : island.openFeature === "music" ? musicExpanded : null
                    Behavior on y { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                    // blurReplace + offset(x: 14) on switching features.
                    property real slide: 0
                    transform: Translate { x: expandedLoader.slide }
                    onLoaded: {
                        if (!island.expanded)
                            return;
                        swapIn.restart();
                        if (island.openFeature === "clipboard" && Shell.keyboardGrab)
                            item.forceActiveFocus();
                    }
                    ParallelAnimation {
                        id: swapIn
                        NumberAnimation { target: expandedLoader; property: "slide"; from: 14; to: 0; duration: 400; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
                        NumberAnimation { target: expandedLoader.item; property: "opacity"; from: 0; to: 1; duration: 250; easing.type: Easing.OutQuad }
                    }
                }

                Item {
                    id: topRow
                    y: island.topRowY
                    width: parent.width
                    height: Metrics.closedHeight

                    LiveActivityView {
                        // Its end-cap content lines up with the 18 px content padding.
                        x: Metrics.padding - Metrics.capInset
                        y: island.activityTop - island.topRowY
                        width: parent.width - 2 * x
                        height: parent.height
                        visible: opacity > 0
                        opacity: island.hasActivity ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 250 } }
                    }

                    // Feature switcher ("ears"): the next feature in front, the
                    // current one tucked behind.
                    Item {
                        id: ears
                        readonly property var stack: island.earsShown ? island.upcomingFeatures.concat([island.openFeature]) : []
                        anchors.right: parent.right
                        anchors.rightMargin: Metrics.padding
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22 + 14 * Math.max(stack.length - 1, 0)
                        height: 22
                        visible: opacity > 0
                        opacity: !island.hasActivity && stack.length > 0 ? 1 : 0
                        scale: opacity > 0 ? 1 : 0.5
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                        Behavior on width { NumberAnimation { duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }

                        Repeater {
                            model: island.allFeatures
                            FeatureLogo {
                                required property string modelData
                                readonly property int depth: ears.stack.indexOf(modelData)
                                feature: modelData
                                visible: depth >= 0
                                x: ears.width - 22 - 14 * Math.max(depth, 0)
                                y: island.hop === modelData ? -4 : 0
                                z: -depth
                                scale: 1 - 0.14 * Math.max(depth, 0)
                                opacity: 1 - 0.35 * Math.max(depth, 0)
                                Behavior on x { NumberAnimation { duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }
                                Behavior on y { NumberAnimation { duration: 350; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                                Behavior on scale { NumberAnimation { duration: 450; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }
                                Behavior on opacity { NumberAnimation { duration: 300 } }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                island.hop = ears.stack[0];
                                island.springy = true;
                                island.switchFeature();
                                hopDone.restart();
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: idleClosed
        IdleClosed {
            source: Settings.idleArt
            crop: Settings.idleArtCrop
        }
    }
    Component {
        id: agentsClosed
        AgentClosed {
            art: Settings.idleArt
        }
    }
    Component {
        id: musicClosed
        MusicClosed {}
    }
    Component {
        id: musicExpanded
        MusicExpanded {}
    }
    Component {
        id: agentList
        AgentList {
            onPicked: sessionId => {
                Agents.focus(sessionId);
                island.setOpen(false);
            }
        }
    }
    Component {
        id: clipboardView
        ClipboardView {
            onPicked: index => island.pick(index)
            onCloseRequested: island.setOpen(false)
        }
    }
}
