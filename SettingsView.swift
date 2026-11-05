import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @Bindable var lab: LabState
    @State private var pane: Pane? = .general
    @State private var openAtLogin = OpenAtLogin.isOn
    @State private var builtInArt: [String: IdleArt] = Dictionary(uniqueKeysWithValues: IdleArt.builtIns.compactMap { name in
        IdleArt.builtIn(name).flatMap(IdleArt.load).map { (name, $0) }
    })

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", music = "Music", agents = "Agents", clipboard = "Clipboard", liveActivities = "Live Activities"
        case lockScreen = "Lock Screen", updates = "Updates"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .music: "music.note"
            case .agents: "sparkles"
            case .clipboard: "list.clipboard.fill"
            case .liveActivities: "dot.radiowaves.left.and.right"
            case .lockScreen: "lock.fill"
            case .updates: "arrow.down.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: .gray
            case .music: Color(red: 1, green: 0.42, blue: 0.55)
            case .agents: Color(red: 0.72, green: 0.5, blue: 0.95)
            case .clipboard: Color(red: 0.2, green: 0.7, blue: 0.65)
            case .liveActivities: .orange
            case .lockScreen: .blue
            case .updates: .green
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(pane.tint.gradient))
                }
                .badge(pane == .updates && lab.updater.phase == .available ? 1 : 0)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Form {
                switch pane ?? .general {
                case .general: general
                case .music: music
                case .agents: agents
                case .clipboard: clipboard
                case .liveActivities: liveActivities
                case .lockScreen: lockScreen
                case .updates: updates
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane?.rawValue ?? "")
        }
        .frame(width: 640, height: 420)
    }

    private var general: some View {
        Group {
            Section {
                Toggle("Show in menu bar", isOn: $lab.showInMenuBar)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in OpenAtLogin.isOn = on }
            } footer: {
                Text("Right-click the notch to open these settings when the menu bar icon is hidden.")
            }
            Section {
                Toggle("Hide in full screen", isOn: $lab.hideInFullscreen)
            } footer: {
                Text("The notch steps aside while an app is in full screen, like a video or a game, and comes back when you leave it.")
            }
            if !LabState.hasNotch {
                Section {
                    Picker("Notch style", selection: $lab.notchStyle) {
                        Text("Island").tag(LabState.NotchStyle.island)
                        Text("Notch").tag(LabState.NotchStyle.notch)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Island floats just below the top of the screen. Notch sits in the menu bar at its height.")
                }
            }
            Section {
                LabeledContent("Notch image") {
                    HStack(spacing: 6) {
                        ForEach(IdleArt.builtIns, id: \.self) { name in
                            Button { lab.setIdleBuiltIn(name) } label: {
                                Group {
                                    if let url = IdleArt.builtIn(name), let art = builtInArt[name] ?? IdleArt.load(url) {
                                        IdleArtView(art: art, size: 26, cornerRadius: 6)
                                    }
                                }
                                .frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 9).fill(.black))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(lab.idleBuiltIn == name ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help(name.replacingOccurrences(of: "-", with: " "))
                        }
                    }
                }
                LabeledContent("Your own") {
                    HStack(spacing: 10) {
                        if let art = lab.idleArt, lab.idleBuiltIn == nil {
                            IdleArtView(art: art, size: 28, cornerRadius: 7)
                        }
                        Button("Choose…") { chooseIdleImage() }
                        if lab.idleArt != nil {
                            Button("Remove") { lab.clearIdleImage() }
                        }
                    }
                }
            } footer: {
                Text("Pick one of niche's own, or choose a picture or GIF. It sits on the left of the notch when no music is showing, next to your agents if any are running. Music and live activities take its place. Best at 64 × 64 pixels or larger, square, with a transparent background. Empty space around the art is trimmed, and GIFs are capped at 300 frames.")
            }
            Section {
                Button("Quit Niche") { NSApp.terminate(nil) }
            }
        }
    }

    private func chooseIdleImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = IdleArt.types
        panel.allowsMultipleSelection = false
        panel.message = "Pick a picture or GIF for the notch"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !lab.setIdleImage(url) {
            let alert = NSAlert()
            alert.messageText = "Niche couldn't open that picture."
            alert.runModal()
        }
    }

    private var music: some View {
        let player = lab.player
        return Group {
            Section {
                Toggle("Show browsers and other players", isOn: Binding(get: { player.allowsAnyApp }, set: { player.allowsAnyApp = $0 }))
            } footer: {
                Text("Off, the notch only follows Music and Spotify. On, it also shows videos playing in a browser and any other app that reports what it plays.")
            }
            Section {
                Toggle("Live visualizer", isOn: $lab.liveVisualizer)
            } footer: {
                Text("Live bars follow the playing app's audio. Capturing it makes macOS show its purple recording indicator; with this off the bars move on their own and nothing is captured.")
            }
            Section {
                Toggle("Lyrics", isOn: Binding(get: { player.allowsLyrics }, set: { player.allowsLyrics = $0 }))
            } footer: {
                Text("Adds a lyrics button to the player. Lyrics come from lrclib.net, deezer and netease, which only see the songs you open lyrics for.")
            }
        }
    }

    private var agents: some View {
        Group {
            Section {
                Toggle("Show agent sessions", isOn: $lab.showAgents)
            } footer: {
                Text("Running agent sessions get a mark in the open notch and their own mode in the feature switcher. Only live sessions are listed.")
            }
            Section("Agents") {
                Toggle(isOn: $lab.showClaude) {
                    Label { Text("Claude Code") } icon: { AgentGlyph(kind: .claude, size: 12) }
                }
                Toggle(isOn: $lab.showOmp) {
                    Label { Text("omp") } icon: { AgentGlyph(kind: .omp, size: 12) }
                }
            }
            .disabled(!lab.showAgents)
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let trusted = AXIsProcessTrusted()
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Text(trusted ? "Allowed" : "Not allowed")
                                .foregroundStyle(trusted ? .green : .orange)
                            if !trusted {
                                Button("Open Settings") {
                                    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Open session on click")
            } footer: {
                Text("Clicking a session switches tmux to its pane and brings the terminal forward. Picking the right terminal tab needs the accessibility permission.")
            }
        }
    }

    private var clipboard: some View {
        let history = lab.clipboard
        return Group {
            Section {
                Toggle("Keep clipboard history", isOn: Binding(get: { history.isOn }, set: { history.isOn = $0 }))
                Stepper(value: Binding(get: { history.limit }, set: { history.limit = $0 }), in: 3...ClipboardHistory.maxLimit) {
                    LabeledContent("Remember", value: "\(history.limit) items")
                }
                .disabled(!history.isOn)
            } footer: {
                Text("Copies stay on this Mac, in memory only, and are gone when Niche quits. Passwords copied from password managers are skipped.")
            }
            Section {
                Toggle("Open with ⌃⌘V", isOn: Binding(get: { history.shortcutOn }, set: { history.shortcutOn = $0 }))
                Toggle("Paste when picking an item", isOn: Binding(get: { history.pastesOnPick }, set: { history.pastesOnPick = $0 }))
            } footer: {
                Text("⌃⌘V opens the clipboard from anywhere: press 1 to 9, or move with the arrows and press Return. Pasting straight into the app you were typing in needs the accessibility permission; without it, the item is copied and you press ⌘V.")
            }
            .disabled(!history.isOn)
            Section {
                Button("Clear history", role: .destructive) { history.clear() }
                    .disabled(history.items.isEmpty)
            }
        }
    }

    private var lockScreen: some View {
        Section {
            Toggle("Show lock indicator", isOn: $lab.showLockIndicator)
        } footer: {
            Text("A padlock sits beside the notch on the lock screen and springs open when you unlock.")
        }
    }

    private var liveActivities: some View {
        let center = lab.liveActivities
        return Group {
            Section {
                Toggle("Live activities", isOn: Binding(get: { center.isOn }, set: { center.isOn = $0 }))
            } footer: {
                Text("Short popups in the closed notch when something changes, then it goes back to what it was showing.")
            }
            Section("Show") {
                ForEach(LiveActivityCenter.Kind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(get: { center.isEnabled(kind) }, set: { center.setEnabled(kind, $0) }))
                }
            }
            .disabled(!center.isOn)
            Section {
                Toggle("Replace the system volume and brightness popups",
                       isOn: Binding(get: { center.replacesSystemHUD }, set: { center.replacesSystemHUD = $0 }))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let trusted = AXIsProcessTrusted()
                    LabeledContent("Accessibility") {
                        HStack(spacing: 8) {
                            Text(trusted ? "Allowed" : "Not allowed")
                                .foregroundStyle(trusted ? .green : .orange)
                            if !trusted {
                                Button("Grant Permission") {
                                    center.requestAccessibility()
                                    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                    if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Niche needs your permission to hide and replace the system volume and brightness popups. It takes over those keys so only the notch shows the change. Focus has no key to take over, so macOS may still show its own Focus banner.")
            }
            .disabled(!center.isOn)
        }
    }

    private var updates: some View {
        let updater = lab.updater
        return Group {
            Section {
                LabeledContent("Installed", value: updater.current)
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        switch updater.phase {
                        case .idle, .checking: ProgressView().controlSize(.small)
                        case .upToDate: Text("Up to date").foregroundStyle(.secondary)
                        case .available: Text("\(updater.latest?.version ?? "") available").foregroundStyle(.green)
                        case .installing: Text("Installing…").foregroundStyle(.secondary)
                        case .failed(let reason): Text(reason).foregroundStyle(.orange).lineLimit(2)
                        }
                        Button("Check now") { Task { await updater.check() } }
                            .disabled(updater.phase == .checking || updater.phase == .installing)
                    }
                }
            } footer: {
                Text("Niche checks GitHub for a new release on launch and every six hours.")
            }
            if let release = updater.latest {
                Section(updater.phase == .available ? "What's new in \(release.version)" : "Latest release, \(release.version)") {
                    Text(LocalizedStringKey(release.notes ?? "No notes for this release."))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if updater.phase == .available || updater.phase == .installing {
                        Button(updater.phase == .installing ? "Installing…" : "Install and restart") {
                            Task { await updater.install() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.phase == .installing)
                    }
                }
            }
        }
    }
}
