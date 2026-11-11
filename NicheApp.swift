import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
@Observable
final class NotchScreen {
    static let shared = NotchScreen()
    private(set) var screen: NSScreen
    private(set) var notch: CGSize?

    private init() {
        guard let screen = NSScreen.screens.first else { fatalError("no screen available") }
        self.screen = screen
        notch = Self.notch(of: screen)
    }

    func refresh() {
        guard let screen = NSScreen.screens.first else {
            NSLog("Niche has no screen, keeping the notch where it was")
            return
        }
        self.screen = screen
        notch = Self.notch(of: screen)
    }

    private static func notch(of screen: NSScreen) -> CGSize? {
        guard !UserDefaults.standard.bool(forKey: "simulateNoNotch"),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}

@MainActor
@Observable
final class LabState {
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    var liveVisualizer: Bool {
        didSet {
            UserDefaults.standard.set(liveVisualizer, forKey: "liveVisualizer")
            player.spectrum.isEnabled = liveVisualizer
        }
    }
    var showAgents: Bool {
        didSet { UserDefaults.standard.set(showAgents, forKey: "showAgents"); applyAgentSettings() }
    }
    var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude"); applyAgentSettings() }
    }
    var showOmp: Bool {
        didSet { UserDefaults.standard.set(showOmp, forKey: "showOmp"); applyAgentSettings() }
    }
    var showLockIndicator: Bool {
        didSet { UserDefaults.standard.set(showLockIndicator, forKey: "showLockIndicator") }
    }
    var hideInFullscreen: Bool {
        didSet { UserDefaults.standard.set(hideInFullscreen, forKey: "hideInFullscreen") }
    }
    enum NotchStyle: String { case island, notch }
    var notchStyle: NotchStyle {
        didSet { UserDefaults.standard.set(notchStyle.rawValue, forKey: "notchStyle"); Self.style = notchStyle }
    }
    enum LockState { case none, locked, unlocking }
    private(set) var lockState = LockState.none
    private(set) var lockShown = false
    private(set) var isDropTarget = false
    private(set) var isAside = false

    let controller = NotchController()
    let player = MusicPlayer()
    let agents = AgentMonitor()
    let updater = Updater()
    let liveActivities = LiveActivityCenter()
    let clipboard = ClipboardHistory()
    private(set) var idleArt: IdleArt?
    enum Feature: CaseIterable { case music, agents, clipboard }
    var selectedFeature: Feature?
    var peekFeature: Feature?
    @ObservationIgnored private var unlockTask: Task<Void, Never>?
    @ObservationIgnored var setKeyCapture: ((Bool) -> Void)?
    @ObservationIgnored private var pulseTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["showInMenuBar": true, "liveVisualizer": false, "showAgents": true,
                                     "showClaude": true, "showOmp": true, "showLockIndicator": true, "hideInFullscreen": false, "notchStyle": "island"])
        self.showInMenuBar = defaults.bool(forKey: "showInMenuBar")
        self.liveVisualizer = defaults.bool(forKey: "liveVisualizer")
        self.showAgents = defaults.bool(forKey: "showAgents")
        self.showClaude = defaults.bool(forKey: "showClaude")
        self.showOmp = defaults.bool(forKey: "showOmp")
        self.showLockIndicator = defaults.bool(forKey: "showLockIndicator")
        self.hideInFullscreen = defaults.bool(forKey: "hideInFullscreen")
        self.notchStyle = defaults.string(forKey: "notchStyle").flatMap(NotchStyle.init(rawValue:)) ?? .island
        Self.style = notchStyle
        player.spectrum.isEnabled = liveVisualizer
        applyAgentSettings()
        agents.onFinished = { [weak self] session in
            guard let self, self.liveActivities.isEnabled(.agentDone), self.liveActivities.isOn else { return }
            self.liveActivities.agentFinished(session.kind)
        }
        clipboard.onCopied = { [weak self] item in
            guard let self, !(self.controller.isExpanded && self.openFeature == .clipboard) else { return }
            self.liveActivities.copied(icon: item.app, image: item.image, color: Self.color(for: item), symbol: Self.symbol(for: item.kind))
        }
        clipboard.onHotKey = { [weak self] in self?.toggleClipboard() }
        liveActivities.showsVolume = { [unowned self] in volumeRoom == 0 }
        if let name = defaults.string(forKey: "idleImage") {
            let url = name.hasPrefix("builtin:") ? IdleArt.builtIn(String(name.dropFirst(8))) : IdleArt.folder.appendingPathComponent(name)
            idleArt = url.flatMap(IdleArt.load)
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenUnlocked() }
        }
    }

    private func applyAgentSettings() {
        var kinds: Set<AgentKind> = []
        if showAgents && showClaude { kinds.insert(.claude) }
        if showAgents && showOmp { kinds.insert(.omp) }
        agents.enabled = kinds
    }
    private static var realNotch: CGSize? { NotchScreen.shared.notch }
    static var hasNotch: Bool { realNotch != nil }
    static var style = NotchStyle.island
    static var isIsland: Bool { !hasNotch && style == .island }
    static var topGap: CGFloat { isIsland ? 3 : 0 }
    static var hardwareNotch: CGSize {
        if let realNotch { return realNotch }
        return CGSize(width: 120, height: isIsland ? 24 : NSStatusBar.system.thickness)
    }
    static var closedArtSize: CGFloat { hasNotch ? 24 : 18 }
    static var closedArtRadius: CGFloat { hasNotch ? 7 : 5 }
    static var closedArtOffset: CGFloat { hasNotch ? -1 : 0 }
    static var closedArtLeading: CGFloat { hasNotch ? 5 : 7 }
    static var closedOffset: CGFloat { hasNotch ? -2 : 0 }
    static func closedSize(hasContent: Bool) -> CGSize {
        CGSize(width: hardwareNotch.width + (hasContent ? 2 * MusicClosedView.slot : 0), height: hardwareNotch.height)
    }
    static var notchExtra: CGFloat { max(0, hardwareNotch.height - 32) }
    static var openSize: CGSize { CGSize(width: hardwareNotch.width + 160, height: 175 + notchExtra) }
    static var agentsWidth: CGFloat { max(openSize.width + 40, 385) }
    static let lyricsWidth: CGFloat = 280
    static var dropSize: CGSize { CGSize(width: closedSize(hasContent: true).width + 40, height: hardwareNotch.height + ClipboardDropZone.height) }

    var hasClosedContent: Bool { shownFeature != nil || idleArt != nil || lockState != .none || liveActivities.current != nil }

    func setIdleImage(_ url: URL) -> Bool {
        let folder = IdleArt.folder
        let name = "idle.\(url.pathExtension.lowercased())"
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("idle.") {
                try FileManager.default.removeItem(at: old)
            }
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            NSLog("Niche could not keep the notch image: %@", String(describing: error))
            return false
        }
        guard let art = IdleArt.load(target) else { return false }
        UserDefaults.standard.set(name, forKey: "idleImage")
        withAnimation(.grow) { idleArt = art }
        return true
    }

    var idleBuiltIn: String? {
        UserDefaults.standard.string(forKey: "idleImage").flatMap { $0.hasPrefix("builtin:") ? String($0.dropFirst(8)) : nil }
    }

    func setIdleBuiltIn(_ name: String) {
        guard let url = IdleArt.builtIn(name), let art = IdleArt.load(url) else { return }
        removeIdleCopy()
        UserDefaults.standard.set("builtin:\(name)", forKey: "idleImage")
        withAnimation(.grow) { idleArt = art }
    }

    private func removeIdleCopy() {
        if let name = UserDefaults.standard.string(forKey: "idleImage"), !name.hasPrefix("builtin:") {
            try? FileManager.default.removeItem(at: IdleArt.folder.appendingPathComponent(name))
        }
    }

    func clearIdleImage() {
        removeIdleCopy()
        UserDefaults.standard.removeObject(forKey: "idleImage")
        withAnimation(.settle) { idleArt = nil }
    }
    var showsAllAgents = false
    var hasOpenableContent: Bool { player.track != nil || !agents.isEmpty || peekFeature == .clipboard }

    static var activityRoomHeight: CGFloat { hardwareNotch.height + (isIsland ? 7 : 0) + 4 - 18 }

    var activityRoom: CGFloat {
        guard controller.isExpanded, liveActivities.current != nil, openFeature != .clipboard else { return 0 }
        return openFeature == .agents && agents.usage.accounts.isEmpty ? 0 : Self.activityRoomHeight
    }

    var volumeRoom: CGFloat {
        controller.isExpanded && openFeature != .agents && openFeature != .clipboard
            && player.track != nil && player.output.isShowingVolume ? 32 : 0
    }

    var agentsHeight: CGFloat { agentsHeight(showingAll: showsAllAgents, room: activityRoom) }

    func agentsHeight(showingAll: Bool, room: CGFloat) -> CGFloat {
        let count = agents.sessions.count
        let rows = showingAll ? count : min(count, AgentSessionList.visibleRows)
        let more = count > AgentSessionList.visibleRows ? AgentSessionList.spacing + AgentSessionList.moreHeight : 0
        let list = CGFloat(rows) * AgentSessionList.rowHeight + CGFloat(max(rows - 1, 0)) * AgentSessionList.spacing + more
        if agents.usage.accounts.isEmpty { return Self.hardwareNotch.height + 2 + list + 16 }
        return 18 + Self.notchExtra + room + UsageStrip.height + 12 + list + 16
    }

    var panelHeight: CGFloat { max(Self.openSize.height, agents.isEmpty ? 0 : agentsHeight(showingAll: true, room: Self.activityRoomHeight)) + 60 }

    var currentSize: CGSize {
        if controller.isExpanded && openFeature == .agents {
            return CGSize(width: agents.usage.accounts.isEmpty ? Self.openSize.width : Self.agentsWidth, height: agentsHeight)
        }
        if controller.isExpanded {
            let lyrics = openFeature != .clipboard && player.track != nil && player.isShowingLyrics ? Self.lyricsWidth : 0
            return CGSize(width: Self.openSize.width + lyrics, height: Self.openSize.height + activityRoom + volumeRoom)
        }
        if isDropTarget { return Self.dropSize }
        let size = Self.closedSize(hasContent: hasClosedContent)
        let room = closedRoom
        return CGSize(width: size.width + room.left + room.right + levelRoom, height: size.height + (hasClosedLyrics ? closedLyricsHeight : 0))
    }

    var usesLyricsShelf: Bool { Self.hasNotch || notchStyle == .notch }

    private var closedMusicIslandHalfRoom: CGFloat {
        ClosedLyricsLayout.islandHalfRoom(lineWidth: player.lyrics.lineWidth, notchWidth: Self.hardwareNotch.width)
    }

    var closedLyricsMetrics: ClosedLyricsLayout.Metrics {
        guard player.isShowingLyrics else { return .empty }
        let width = ClosedLyricsLayout.availableWidth(
            usesShelf: usesLyricsShelf,
            closedWidth: Self.closedSize(hasContent: true).width,
            notchWidth: Self.hardwareNotch.width,
            islandHalfRoom: usesLyricsShelf ? 0 : closedMusicIslandHalfRoom
        )
        return ClosedLyricsLayout.metrics(for: player.lyrics.line, width: width)
    }

    var closedLyricsHeight: CGFloat {
        ClosedLyricsLayout.extraHeight(
            for: closedLyricsMetrics,
            usesShelf: usesLyricsShelf,
            notchHeight: Self.hardwareNotch.height
        )
    }

    var hasClosedLyrics: Bool {
        !controller.isExpanded && !isDropTarget && lockState == .none && liveActivities.current == nil
            && shownFeature == .music && player.isShowingLyrics && !player.lyrics.line.isEmpty
    }

    var closedRoom: (left: CGFloat, right: CGFloat) {
        guard !controller.isExpanded, !isDropTarget, lockState == .none, liveActivities.current == nil else { return (0, 0) }
        if shownFeature == nil { return idleArt != nil ? (-5, -MusicClosedView.slot) : (0, 0) }
        if shownFeature == .music && player.isShowingLyrics && !usesLyricsShelf {
            let half = closedMusicIslandHalfRoom
            return (half, half)
        }
        guard shownFeature == .agents else { return (0, 0) }
        let kinds = AgentKind.allCases.filter { !agents.sessions(of: $0).isEmpty }.count
        guard kinds > 1 else { return (0, 0) }
        return idleArt != nil ? (0, 26) : (10, 0)
    }

    var levelRoom: CGFloat {
        guard !controller.isExpanded, !isDropTarget, lockState == .none, let activity = liveActivities.current else { return 0 }
        return LiveActivityView.room(for: activity)
    }

    var closedOffset: CGFloat {
        let room = closedRoom
        return (room.right + levelRoom - room.left) / 2
    }

    var activeFeatures: [Feature] {
        Feature.allCases.filter {
            switch $0 {
            case .music: player.track != nil
            case .agents: !agents.isEmpty
            case .clipboard: false
            }
        }
    }

    var shownFeature: Feature? {
        if let feature = selectedFeature, activeFeatures.contains(feature) { return feature }
        return activeFeatures.first
    }

    var openFeature: Feature? {
        if peekFeature == .clipboard && !clipboard.items.isEmpty { return .clipboard }
        if let feature = peekFeature, activeFeatures.contains(feature) { return feature }
        return shownFeature
    }

    var upcomingFeatures: [Feature] {
        let live = activeFeatures
        guard let current = openFeature, let index = live.firstIndex(of: current) else { return [] }
        return (1..<live.count).map { live[(index + $0) % live.count] }
    }

    func switchFeature() {
        guard let next = upcomingFeatures.first else { return }
        peekFeature = nil
        selectedFeature = next
    }

    func toggleClipboard() {
        guard lockState == .none, !clipboard.items.isEmpty else { return }
        if controller.isExpanded && openFeature == .clipboard {
            setOpen(false)
            return
        }
        clipboard.setKeyboard(true)
        peekFeature = .clipboard
        setOpen(true)
        setKeyCapture?(true)
    }

    func pick(_ item: ClipboardHistory.Item) {
        clipboard.copy(clipboard.marked.isEmpty ? [item] : clipboard.markedItems)
        setOpen(false)
        guard clipboard.pastesOnPick && AXIsProcessTrusted() else {
            liveActivities.copied(icon: item.app, image: item.image, color: Self.color(for: item), symbol: Self.symbol(for: item.kind))
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.12))
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func clipboardKey(_ event: NSEvent) {
        let items = clipboard.items
        guard !items.isEmpty else { return setOpen(false) }
        let columns = 5
        var selection = clipboard.selection
        let current = items[min(selection, items.count - 1)]
        if event.modifierFlags.contains(.command) && Int(event.keyCode) == kVK_ANSI_A { return clipboard.markAll() }
        switch Int(event.keyCode) {
        case kVK_Escape: return clipboard.marked.isEmpty ? setOpen(false) : clipboard.unmark()
        case kVK_Space: return clipboard.mark(current)
        case kVK_Return, kVK_ANSI_KeypadEnter: return pick(current)
        case kVK_Delete, kVK_ForwardDelete: return clipboard.remove(current)
        case kVK_LeftArrow: selection -= 1
        case kVK_RightArrow: selection += 1
        case kVK_UpArrow: selection -= columns
        case kVK_DownArrow: selection += columns
        default:
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit), digit <= items.count {
                clipboard.marked.isEmpty ? pick(items[digit - 1]) : clipboard.mark(items[digit - 1])
            }
            return
        }
        clipboard.selection = min(max(selection, 0), items.count - 1)
    }

    static func color(for item: ClipboardHistory.Item) -> Color? {
        item.kind == .color ? ClipboardHistory.color(from: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    static func symbol(for kind: ClipboardHistory.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette.fill"
        case .image: "photo"
        case .files: "doc.fill"
        }
    }

    func hover(_ inside: Bool) {
        if isDropTarget || (inside && !controller.isExpanded && NSEvent.pressedMouseButtons != 0) { return }
        if !hasOpenableContent && lockState == .none && !controller.isExpanded {
            if inside { pulse() }
            return
        }
        setOpen(inside && lockState == .none)
    }

    var canDrop: Bool { clipboard.isOn && lockState == .none }

    func setDropTarget(_ on: Bool) {
        guard on != isDropTarget else { return }
        withAnimation(on ? .grow : .settle) {
            isDropTarget = on
        }
    }

    func setAside(_ on: Bool) {
        guard on != isAside else { return }
        if on { setOpen(false) }
        withAnimation(on ? .close : .grow) {
            isAside = on
        }
    }

    private func pulse() {
        pulseTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { controller.isLifted = true }
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.18))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 1)) { self?.controller.isLifted = false }
        }
    }

    private func screenLocked() {
        unlockTask?.cancel()
        guard showLockIndicator else { return }
        setOpen(false)
        withAnimation(.arrive) {
            lockState = .locked
            lockShown = true
        }
    }

    private func screenUnlocked() {
        guard lockState == .locked else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { lockState = .unlocking }
        unlockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.lockShown = false }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.settle) { self.lockState = .none }
        }
    }

    func setOpen(_ open: Bool) {
        let c = controller
        guard open != c.isExpanded || c.isCollapsing else { return }
        if open {
            c.expand()
        } else {
            c.collapse()
            peekFeature = nil
            player.output.isShowingVolume = false
            showsAllAgents = false
            clipboard.setKeyboard(false)
            setKeyCapture?(false)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }
}

struct NicheView: View {
    let lab: LabState
    @State private var closedFeature = LabState.Feature.music
    @State private var hop: LabState.Feature?

    var body: some View {
        let c = lab.controller
        let size = lab.currentSize
        let island = lab.notchStyle == .island && !LabState.hasNotch
        let radii = c.isRounded || lab.isDropTarget ? (top: 16.0, bottom: 22.0) : (top: 8.0, bottom: island ? size.height / 2 : (lab.hasClosedLyrics ? 14.0 : 12.0))
        let outlineWidth = size.width + 2 * radii.top
        let shape = NotchShape(topCornerRadius: radii.top, bottomCornerRadius: radii.bottom, isIsland: island)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                shape
                    .fill(.black)
                if c.isExpanded {
                    ZStack(alignment: .top) {
                        Group {
                            if lab.openFeature == .agents {
                                VStack(spacing: 12) {
                                    if !lab.agents.usage.accounts.isEmpty {
                                        UsageStrip(accounts: lab.agents.usage.accounts, room: lab.activityRoom)
                                    }
                                    AgentSessionList(sessions: lab.agents.sessions, showsAll: lab.showsAllAgents, onToggleAll: {
                                        withAnimation(.arrive) { lab.showsAllAgents.toggle() }
                                    }) { session in
                                        lab.agents.focus(session)
                                        lab.setOpen(false)
                                    }
                                }
                                    .frame(width: (lab.agents.usage.accounts.isEmpty ? LabState.openSize.width : LabState.agentsWidth) - 2 * 18,
                                           alignment: .top)
                                    .padding(.top, lab.agents.usage.accounts.isEmpty ? LabState.hardwareNotch.height + 2 : 18 + LabState.notchExtra + lab.activityRoom)
                            } else if lab.openFeature == .clipboard {
                                ClipboardView(history: lab.clipboard) { lab.pick($0) }
                                    .frame(width: LabState.openSize.width - 2 * 18,
                                           height: LabState.openSize.height - LabState.hardwareNotch.height - 16, alignment: .top)
                                    .padding(.top, LabState.hardwareNotch.height + 4)
                            } else {
                                MusicExpandedView(player: lab.player, width: LabState.openSize.width - 2 * 18)
                                    .padding(.top, 18 + LabState.notchExtra + lab.activityRoom)
                            }
                        }
                        .id(lab.openFeature)
                        .transition(.asymmetric(
                            insertion: AnyTransition(.blurReplace).combined(with: .offset(x: 14))
                                .animation(.arrive),
                            removal: AnyTransition(.blurReplace).combined(with: .offset(x: -14))
                                .animation(.exit)))
                    }
                        .frame(width: size.width + 2 * 16, height: size.height, alignment: .top)
                        .overlay(alignment: .top) { topRow }
                        .drawingGroup()
                        .blur(radius: c.isSharp ? 0 : 5)
                        .transition(.asymmetric(insertion: .opacity.animation(.fadeIn.delay(0.12)),
                                                removal: .opacity.animation(.fadeOut)))
                } else if lab.isDropTarget {
                    ClipboardDropZone(item: lab.clipboard.dropping)
                        .padding(.top, LabState.hardwareNotch.height)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .transition(.asymmetric(insertion: .opacity.animation(.fadeIn.delay(0.12)),
                                                removal: .opacity.animation(.fadeOut)))
                } else if lab.lockState != .none {
                    LockIndicator(state: lab.lockState, isShown: lab.lockShown)
                        .frame(width: LabState.closedSize(hasContent: true).width, height: LabState.hardwareNotch.height)
                        .transition(.identity)
                } else if let activity = lab.liveActivities.current {
                    LiveActivityView(activity: activity)
                        .id(activity.kind)
                        .frame(width: LabState.closedSize(hasContent: true).width + lab.levelRoom, height: LabState.hardwareNotch.height)
                        .drawingGroup()
                        .modifier(ActivityFade(isShown: lab.liveActivities.isShowing))
                        .transition(Self.activityTransition)
                } else {
                    Group {
                        if closedFeature == .agents || (lab.shownFeature == nil && lab.idleArt != nil) {
                            AgentClosedView(monitor: lab.agents, art: lab.idleArt)
                        } else {
                            MusicClosedView(player: lab.player, lab: lab)
                        }
                    }
                        .frame(width: LabState.closedSize(hasContent: true).width + lab.closedRoom.left + lab.closedRoom.right, height: size.height, alignment: .top)
                        .modifier(ClosedContentFade(isShown: lab.hasClosedContent))
                        .transition(Self.closedContentTransition(afterClosing: c.isCollapsing || c.isExpanded))
                }
                shape
                    .stroke(LinearGradient(stops: [.init(color: .white.opacity(0.28), location: 0),
                                                   .init(color: .white.opacity(0.28), location: 0.25),
                                                   .init(color: .white.opacity(0), location: 0.75)],
                                           startPoint: .bottom, endPoint: .top),
                            lineWidth: 2)
                    .animation(.easeOut(duration: 0.35)) { $0.opacity(c.isExpanded || lab.isDropTarget ? 1 : 0) }
                    .allowsHitTesting(false)
            }
            .frame(width: outlineWidth, height: size.height, alignment: .top)
            .clipShape(shape)
            .background {
                shape
                    .fill(.black)
                    .animation(.easeOut(duration: 0.35)) { $0.shadow(color: .black.opacity(c.isExpanded || lab.isDropTarget ? 0.55 : 0), radius: 14, y: 4) }
            }
            .modifier(NotchSquashModifier(controller: c))
            .offset(x: lab.closedOffset)
            .animation(c.isCollapsing ? .close : closedResize, value: lab.closedOffset)
            .scaleEffect(lab.isAside ? 0.6 : 1, anchor: .top)
            .blur(radius: lab.isAside ? 6 : 0)
            .opacity(lab.isAside ? 0 : 1)
            .padding(.top, LabState.topGap)
            .contentShape(Rectangle())
            .onHover { lab.hover($0) }
            .onChange(of: lab.hasOpenableContent) { _, has in if !has { lab.setOpen(false) } }
            .onChange(of: lab.shownFeature, initial: true) { _, feature in
                if let feature { closedFeature = feature }
            }
            .onChange(of: lab.player.isPlaying) { _, playing in
                if playing { lab.selectedFeature = .music }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !c.isExpanded else { return }
                        c.isPressed = abs(value.translation.height) < 4
                        c.stretch = max(-1, min(1, -value.translation.height / 60))
                    }
                    .onEnded { _ in
                        withAnimation(.close) {
                            c.isPressed = false
                            c.stretch = 0
                        }
                    }
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(closedResize, value: lab.hasClosedContent)
        .animation(.spring(response: 0.45, dampingFraction: 0.95), value: lab.closedLyricsHeight)
    }

    private var closedResize: Animation {
        lab.hasClosedContent
            ? .grow
            : .settle
    }

    private static let activityTransition = AnyTransition.asymmetric(
        insertion: AnyTransition(.blurReplace).animation(.arrive),
        removal: .identity)

    private static func closedContentTransition(afterClosing: Bool) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.fadeIn.delay(afterClosing ? 0.25 : 0.05)),
                    removal: .opacity.animation(.fadeOut))
    }

    @ViewBuilder private var topRow: some View {
        if let activity = lab.liveActivities.current {
            LiveActivityView(activity: activity)
                .id(activity.kind)
                .padding(.horizontal, 16 + (islandInset ? 16 : 4))
                .frame(height: LabState.hardwareNotch.height)
                .padding(.top, islandInset ? 7 : 0)
                .modifier(ActivityFade(isShown: lab.liveActivities.isShowing))
                .transition(Self.activityTransition)
        } else {
            ears
                .transition(.opacity.animation(.fadeIn.delay(0.1)))
        }
    }

    private var ears: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            let upcoming = lab.upcomingFeatures
            if !upcoming.isEmpty, let current = lab.openFeature {
                let stack = upcoming + [current]
                Button {
                    hop = stack.first
                    withAnimation(.arrive) { lab.switchFeature() }
                    Task {
                        try? await Task.sleep(for: .seconds(0.16))
                        withAnimation(.glyph) { hop = nil }
                    }
                } label: {
                    ZStack {
                        ForEach(LabState.Feature.allCases.filter(stack.contains), id: \.self) { feature in
                            let depth = CGFloat(stack.firstIndex(of: feature) ?? 0)
                            FeatureLogo(feature: feature)
                                .scaleEffect(1 - 0.14 * depth)
                                .offset(x: -14 * depth, y: hop == feature ? -4 : 0)
                                .opacity(1 - 0.35 * Double(depth))
                                .zIndex(-Double(depth))
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .frame(width: 22 + 14 * CGFloat(stack.count - 1), height: 22, alignment: .trailing)
                    .animation(.arrive, value: stack)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16 + (islandInset ? 16 : 6))
        .frame(height: LabState.hardwareNotch.height)
        .padding(.top, islandInset ? 7 : 0)
    }

    private var islandInset: Bool { lab.notchStyle == .island && !LabState.hasNotch }
}

struct ActivityFade: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .blur(radius: isShown ? 0 : 6)
            .scaleEffect(isShown ? 1 : 0.9)
    }
}

struct ClosedContentFade: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown ? 1 : 0.75)
            .blur(radius: isShown ? 0 : 4)
            .animation(isShown ? .arrive.delay(0.18)
                               : .settle,
                       value: isShown)
    }
}

struct FeatureLogo: View {
    let feature: LabState.Feature

    var body: some View {
        let (symbol, tint): (String, Color) = switch feature {
        case .music: ("music.note", Color(red: 1, green: 0.42, blue: 0.55))
        case .agents: ("sparkles", Color(red: 0.85, green: 0.6, blue: 1))
        case .clipboard: ("list.clipboard.fill", Color(red: 0.45, green: 0.85, blue: 0.8))
        }
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(white: 0.16)))
            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
    }
}

struct LockIndicator: View {
    let state: LabState.LockState
    let isShown: Bool
    @State private var lift: CGFloat = 0.8
    @State private var swing: Double = 180
    @State private var squash: CGFloat = 1
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Shackle()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: 6 - 1.2 * swing / 180, height: 8 - 2 * swing / 180)
                    .rotation3DEffect(.degrees(swing), axis: (x: 0, y: 1, z: 0), anchor: .trailing, perspective: 0)
                    .offset(y: -4.1 - lift)
                RoundedRectangle(cornerRadius: 1.9)
                    .fill(.white)
                    .frame(width: 8.8, height: 6.6)
                    .scaleEffect(x: 2 - squash, y: squash, anchor: .bottom)
            }
            .frame(width: 13, height: 14, alignment: .bottom)
            .frame(width: MusicClosedView.slot)
            Spacer(minLength: 0)
        }
        .opacity(isShown && appeared ? 1 : 0)
        .blur(radius: isShown && appeared ? 0 : 6)
        .scaleEffect(isShown && appeared ? 1 : 0.85, anchor: .leading)
        .task { await latch() }
        .onChange(of: state) { _, state in
            if state == .unlocking { Task { await unlatch() } }
        }
    }

    private func latch() async {
        withAnimation(.easeOut(duration: 0.35)) { appeared = true }
        try? await Task.sleep(for: .seconds(0.55))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { swing = 0 }
        try? await Task.sleep(for: .seconds(0.25))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { lift = 0 }
        try? await Task.sleep(for: .seconds(0.08))
        withAnimation(.easeOut(duration: 0.05)) { squash = 0.88 }
        try? await Task.sleep(for: .seconds(0.05))
        withAnimation(.spring(response: 0.25, dampingFraction: 0.45)) { squash = 1 }
    }

    private func unlatch() async {
        withAnimation(.easeOut(duration: 0.06)) { squash = 0.88 }
        try? await Task.sleep(for: .seconds(0.06))
        withAnimation(.spring(response: 0.28, dampingFraction: 0.4)) {
            squash = 1
            lift = 0.8
        }
        try? await Task.sleep(for: .seconds(0.1))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { swing = 180 }
    }
}

private struct Shackle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width / 2
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

@_silgen_name("_CGSDefaultConnection") private func CGSDefaultConnection() -> UInt
@_silgen_name("CGSSpaceCreate") private func CGSSpaceCreate(_ cid: UInt, _ flag: Int, _ options: NSDictionary?) -> UInt64
@_silgen_name("CGSSpaceSetAbsoluteLevel") private func CGSSpaceSetAbsoluteLevel(_ cid: UInt, _ space: UInt64, _ level: Int)
@_silgen_name("CGSShowSpaces") private func CGSShowSpaces(_ cid: UInt, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces") private func CGSHideSpaces(_ cid: UInt, _ spaces: NSArray)
@_silgen_name("CGSSpaceDestroy") private func CGSSpaceDestroy(_ cid: UInt, _ space: UInt64)
@_silgen_name("CGSManagedDisplayGetCurrentSpace") private func CGSManagedDisplayGetCurrentSpace(_ cid: UInt, _ display: CFString) -> UInt64
@_silgen_name("CGSSpaceGetType") private func CGSSpaceGetType(_ cid: UInt, _ space: UInt64) -> Int
@_silgen_name("CGSAddWindowsToSpaces") private func CGSAddWindowsToSpaces(_ cid: UInt, _ windows: NSArray, _ spaces: NSArray)

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lab = LabState()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var keyCatcher: KeyCatcher?
    private var notchSpace: UInt64 = 0
    private var monitors: [Any] = []
    private var playbackTimer: Timer?
    private var shrinkTask: Task<Void, Never>?
    private var dropCatcher: NSPanel!
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NSPanel(contentRect: Self.panelFrame(height: lab.panelHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.canBecomeVisibleWithoutLogin = true
        let host = NSHostingView(rootView: NicheView(lab: lab))
        host.sizingOptions = []
        panel.contentView = host
        panel.orderFrontRegardless()

        dropCatcher = NSPanel(contentRect: Self.dropFrame(), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dropCatcher.isOpaque = false
        dropCatcher.backgroundColor = .clear
        dropCatcher.hasShadow = false
        dropCatcher.level = .statusBar
        dropCatcher.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        dropCatcher.ignoresMouseEvents = true
        dropCatcher.contentView = DropCatcherView(lab: lab)
        dropCatcher.orderFrontRegardless()

        let cid = CGSDefaultConnection()
        notchSpace = CGSSpaceCreate(cid, 0x1, nil)
        CGSSpaceSetAbsoluteLevel(cid, notchSpace, 400)
        CGSShowSpaces(cid, [notchSpace] as NSArray)
        CGSAddWindowsToSpaces(cid, [panel.windowNumber] as NSArray, [notchSpace] as NSArray)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.isVisible = lab.showInMenuBar
        trackSettings()
        trackPanelHeight()

        lab.player.start()
        lab.player.output.start()
        lab.agents.start()
        lab.updater.start()
        lab.liveActivities.start()
        lab.clipboard.start()
        let catcher = KeyCatcher()
        catcher.onKey = { [weak self] in self?.lab.clipboardKey($0) }
        keyCatcher = catcher
        lab.setKeyCapture = { [weak catcher] on in
            if on { catcher?.makeKeyAndOrderFront(nil) } else { catcher?.orderOut(nil) }
        }
        monitors.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: catcher, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lab.clipboard.isKeyboard else { return }
                self.lab.setOpen(false)
            }
        })
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lab.player.tick() }
        }

        let update: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            let notch = self.lab.currentSize
            let gap = LabState.topGap
            let panelFrame = self.panel.frame
            let hit = NSRect(x: panelFrame.midX + self.lab.closedOffset - notch.width / 2 - 8, y: panelFrame.maxY - gap - notch.height - 8,
                             width: notch.width + 16, height: gap + notch.height + 8)
            self.panel.ignoresMouseEvents = self.lab.isAside || !hit.contains(NSEvent.mouseLocation)
            self.dropCatcher.ignoresMouseEvents = self.lab.isAside || event.type != .leftMouseDragged
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: update) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { update($0); return $0 } as Any)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.panel, let view = self.panel.contentView else { return event }
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings", action: #selector(self.openSettings), keyEquivalent: "").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        } as Any)

        monitors.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenChanged() }
        })
        monitors.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyFullscreen() }
        })
        applyFullscreen()

        if !UserDefaults.standard.bool(forKey: "onboarded") { openOnboarding() }
    }

    private static func panelFrame(height: CGFloat) -> NSRect {
        let screen = NotchScreen.shared.screen.frame
        let width = max(LabState.openSize.width + LabState.lyricsWidth + 80, LabState.agentsWidth + 40)
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    private func screenChanged() {
        NotchScreen.shared.refresh()
        panel.setFrame(Self.panelFrame(height: lab.panelHeight), display: true)
        dropCatcher.setFrame(Self.dropFrame(), display: false)
        applyFullscreen()
    }

    private func applyFullscreen() {
        lab.setAside(lab.hideInFullscreen && Self.screenIsFullscreen() && lab.liveActivities.current == nil)
        if lab.isAside { panel.ignoresMouseEvents = true }
    }

    private static func screenIsFullscreen() -> Bool {
        let screen = NotchScreen.shared.screen
        let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let uuid = CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(display).takeRetainedValue())!
        let cid = CGSDefaultConnection()
        return CGSSpaceGetType(cid, CGSManagedDisplayGetCurrentSpace(cid, uuid)) == 4
    }

    private static func dropFrame() -> NSRect {
        let screen = NotchScreen.shared.screen.frame
        let size = LabState.dropSize
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - LabState.topGap - size.height,
                      width: size.width, height: LabState.topGap + size.height)
    }

    private func trackPanelHeight() {
        let height = withObservationTracking { lab.panelHeight } onChange: { [weak self] in
            Task { @MainActor in self?.trackPanelHeight() }
        }
        shrinkTask?.cancel()
        if height > panel.frame.height {
            panel.setFrame(Self.panelFrame(height: height), display: true)
        } else if height < panel.frame.height {
            shrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled, let self else { return }
                self.panel.setFrame(Self.panelFrame(height: height), display: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lab.player.stop()
        lab.liveActivities.stop()
        let cid = CGSDefaultConnection()
        CGSHideSpaces(cid, [notchSpace] as NSArray)
        CGSSpaceDestroy(cid, notchSpace)
    }

    private func trackSettings() {
        withObservationTracking {
            _ = lab.showInMenuBar
            _ = lab.hideInFullscreen
            _ = lab.liveActivities.current
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.isVisible = self.lab.showInMenuBar
                self.applyFullscreen()
                self.trackSettings()
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(lab: lab)))
            window.title = "Niche Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 420))
            settingsWindow = window
            monitors.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.settingsWindow = nil }
            })
        }
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openOnboarding() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(lab: lab) { [weak window] in window?.close() })
        window.setContentSize(window.contentView!.fittingSize)
        monitors.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            UserDefaults.standard.set(true, forKey: "onboarded")
            Task { @MainActor in self?.onboardingWindow = nil }
        })
        onboardingWindow = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            let x0: CGFloat = 2, x1: CGFloat = 18, y0: CGFloat = 2.5, y1: CGFloat = 13.5
            let nl: CGFloat = 10 - 3.4, nr: CGFloat = 10 + 3.4, depth: CGFloat = 2.6
            let corners: [(CGPoint, CGFloat)] = [
                (CGPoint(x: x0, y: y1), 3.6), (CGPoint(x: nl, y: y1), 0.8), (CGPoint(x: nl, y: y1 - depth), 1.2),
                (CGPoint(x: nr, y: y1 - depth), 1.2), (CGPoint(x: nr, y: y1), 0.8), (CGPoint(x: x1, y: y1), 3.6),
                (CGPoint(x: x1, y: y0), 3.6), (CGPoint(x: x0, y: y0), 3.6),
            ]
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x0, y: 8))
            for i in corners.indices {
                path.addArc(tangent1End: corners[i].0, tangent2End: corners[(i + 1) % corners.count].0, radius: corners[i].1)
            }
            path.closeSubpath()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setLineWidth(1.6)
            ctx.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

