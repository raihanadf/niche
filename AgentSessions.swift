import AppKit
import SwiftUI

enum AgentKind: CaseIterable {
    case claude, omp
}

struct AgentSession: Identifiable, Equatable {
    enum State { case working, paused }
    let id: String
    let kind: AgentKind
    let title: String?
    let account: String?
    let project: String
    let state: State
    let pid: pid_t
}

@MainActor
@Observable
final class AgentMonitor {
    private(set) var sessions: [AgentSession] = []
    let usage = AgentUsage()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "niche.agents", qos: .utility)
    @ObservationIgnored var enabled: Set<AgentKind> = [] {
        didSet { refresh() }
    }
    @ObservationIgnored var onFinished: ((AgentSession) -> Void)?

    var isEmpty: Bool { sessions.isEmpty }

    func sessions(of kind: AgentKind) -> [AgentSession] {
        sessions.filter { $0.kind == kind }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let kinds = enabled
        queue.async { [weak self] in
            let found = (kinds.contains(.claude) ? Self.claudeSessions() : []) + (kinds.contains(.omp) ? Self.ompSessions() : [])
            Task { @MainActor in
                guard let self else { return }
                let live = found.filter { self.enabled.contains($0.kind) }
                if !live.isEmpty { self.usage.refresh(kinds: self.enabled) }
                guard self.sessions != live else { return }
                let wasWorking = Set(self.sessions.filter { $0.state == .working }.map(\.id))
                for session in live where session.state == .paused && wasWorking.contains(session.id) {
                    self.onFinished?(session)
                }
                withAnimation(.spring(Spring(duration: 0.35, bounce: 0.3), blendDuration: 0)) { self.sessions = live }
            }
        }
    }

    func focus(_ session: AgentSession) {
        queue.async { Self.focus(pid: session.pid) }
    }

    nonisolated private static func focus(pid: pid_t) {
        var parents: [pid_t: pid_t] = [:]
        for line in run("/bin/ps", ["-Ao", "pid=,ppid="]).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let child = pid_t(parts[0]), let parent = pid_t(parts[1]) { parents[child] = parent }
        }
        func ancestors(of start: pid_t) -> [pid_t] {
            var chain: [pid_t] = []
            var current: pid_t? = start
            while let pid = current, pid > 1 {
                chain.append(pid)
                current = parents[pid]
            }
            return chain
        }

        var appPID = pid
        let ownTTY = run("/bin/ps", ["-o", "tty=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        var tty: String? = ownTTY.hasPrefix("ttys") ? "/dev/\(ownTTY)" : nil
        let tmux = ["/run/current-system/sw/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let tmux {
            var panes: [pid_t: (session: String, window: String, pane: String)] = [:]
            for line in run(tmux, ["list-panes", "-a", "-F", "#{pane_pid} #{session_name} #{window_id} #{pane_id}"]).split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 4, let shell = pid_t(parts[0]) {
                    panes[shell] = (String(parts[1]), String(parts[2]), String(parts[3]))
                }
            }
            let client = run(tmux, ["list-clients", "-F", "#{client_activity} #{client_name} #{client_pid} #{client_tty}"])
                .split(separator: "\n")
                .compactMap { line -> (activity: Int, name: String, pid: pid_t, tty: String)? in
                    let parts = line.split(separator: " ")
                    guard parts.count == 4, let activity = Int(parts[0]), let pid = pid_t(parts[2]) else { return nil }
                    return (activity, String(parts[1]), pid, String(parts[3]))
                }
                .max { $0.activity < $1.activity }
            if let target = ancestors(of: pid).lazy.compactMap({ panes[$0] }).first, let client {
                _ = run(tmux, ["switch-client", "-c", client.name, "-t", target.session])
                _ = run(tmux, ["select-window", "-t", target.window])
                _ = run(tmux, ["select-pane", "-t", target.pane])
                appPID = client.pid
                tty = client.tty
            }
        }

        let terminals = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "net.kovidgoyal.kitty",
                         "org.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable"]
        let app = ancestors(of: appPID).lazy.compactMap({ NSRunningApplication(processIdentifier: $0) })
            .first(where: { $0.activationPolicy == .regular })
            ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier.map(terminals.contains) == true }
        guard let app, let url = app.bundleURL else {
            NSLog("Niche found no terminal app for pid %d", appPID)
            return
        }
        if let tty { selectTab(in: app.processIdentifier, showing: tty) }
        DispatchQueue.main.async {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    nonisolated private static func selectTab(in appPID: pid_t, showing tty: String) {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
            NSLog("Niche needs the accessibility permission to pick the terminal tab")
            return
        }
        let app = AXUIElementCreateApplication(appPID)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func titled() -> [(element: AXUIElement, window: AXUIElement, title: String)] {
            let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            return windows.flatMap { window -> [(AXUIElement, AXUIElement, String)] in
                let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
                let tabs = children.filter { attribute($0, kAXRoleAttribute) as? String == kAXTabGroupRole }
                    .flatMap { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                    .filter { attribute($0, kAXRoleAttribute) as? String == kAXRadioButtonRole }
                return ([window] + tabs).compactMap { element in
                    (attribute(element, kAXTitleAttribute) as? String).map { (element, window, $0) }
                }
            }
        }
        guard let handle = FileHandle(forWritingAtPath: tty) else {
            NSLog("Niche cannot write to %@", tty)
            return
        }
        defer { try? handle.close() }

        let before = titled()
        let marker = "niche-\(UUID().uuidString.prefix(8))"
        handle.write(Data("\u{1b}]2;\(marker)\u{07}".utf8))
        for _ in 0..<20 {
            usleep(25_000)
            guard titled().contains(where: { $0.title == marker }) else { continue }
            usleep(150_000)
            let now = titled()
            guard let index = now.firstIndex(where: { $0.title == marker && $0.element != $0.window })
                    ?? now.firstIndex(where: { $0.title == marker }) else { continue }
            let hit = now[index]
            AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
            if hit.element != hit.window { AXUIElementPerformAction(hit.element, kAXPressAction as CFString) }
            if before.count == now.count {
                usleep(300_000)
                handle.write(Data("\u{1b}]2;\(before[index].title)\u{07}".utf8))
            }
            return
        }
        NSLog("Niche found no tab titled %@", marker)
    }

    nonisolated private static func claudeSessions() -> [AgentSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let entries = try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) else { return [] }
        var found: [AgentSession] = []
        for config in entries where config.lastPathComponent.hasPrefix(".claude") {
            guard let files = try? fm.contentsOfDirectory(at: config.appending(path: "sessions"), includingPropertiesForKeys: nil) else { continue }
            let projectDirs = try? fm.contentsOfDirectory(at: config.appending(path: "projects"), includingPropertiesForKeys: nil)
            let suffix = config.lastPathComponent.dropFirst(".claude".count).drop { $0 == "-" }
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = info["pid"] as? Int, kill(pid_t(pid), 0) == 0,
                      let sessionID = info["sessionId"] as? String,
                      let cwd = info["cwd"] as? String,
                      let status = info["status"] as? String else { continue }

                var title = info["name"] as? String
                if let transcript = projectDirs?.map({ $0.appending(path: "\(sessionID).jsonl") })
                    .first(where: { fm.fileExists(atPath: $0.path) }) {
                    for line in tailLines(of: transcript, bytes: 256 * 1024).reversed() where line.contains("\"ai-title\"") {
                        if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                           let aiTitle = entry["aiTitle"] as? String {
                            title = aiTitle
                            break
                        }
                    }
                }
                found.append(AgentSession(id: "claude-\(sessionID)", kind: .claude, title: title,
                                          account: suffix.isEmpty ? nil : String(suffix),
                                          project: URL(fileURLWithPath: cwd).lastPathComponent,
                                          state: status == "busy" || status == "shell" ? .working : .paused,
                                          pid: pid_t(pid)))
            }
        }
        return found.sorted { $0.id < $1.id }
    }

    nonisolated private static func ompSessions() -> [AgentSession] {
        let rows = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="]).split(separator: "\n").compactMap { line -> (pid: String, ppid: String, tty: String)? in
            let parts = line.split(separator: " ")
            guard parts.count >= 4, parts.dropFirst(3).contains(where: { $0.hasSuffix("/bin/omp") }) else { return nil }
            return (String(parts[0]), String(parts[1]), String(parts[2]))
        }
        let pids = Set(rows.map(\.pid))
        let terminals = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omp/agent/terminal-sessions")
        var found: [AgentSession] = []
        for launcher in rows where !pids.contains(launcher.ppid) && launcher.tty.hasPrefix("ttys") {
            guard let pid = pid_t(launcher.pid),
                  let pointer = try? String(contentsOf: terminals.appending(path: launcher.tty), encoding: .utf8) else { continue }
            let lines = pointer.split(separator: "\n")
            guard lines.count >= 2 else { continue }
            let file = URL(fileURLWithPath: String(lines[1]))
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
            try? handle.close()

            let title = head.split(separator: "\n").prefix(3).lazy
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["type"] as? String == "title" }?["title"] as? String

            var state: AgentSession.State? = .paused
            for line in tailLines(of: file, bytes: 64 * 1024).reversed() {
                if line.contains("\"customType\":\"session_exit\"") { state = nil; break }
                if line.contains("\"customType\":\"tool_execution_start\"") { state = .working; break }
                guard line.hasPrefix("{\"type\":\"message\""),
                      let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = entry["message"] as? [String: Any],
                      let role = message["role"] as? String else { continue }
                state = role == "assistant" && message["stopReason"] as? String != "toolUse" ? .paused : .working
                break
            }
            guard let state else { continue }
            found.append(AgentSession(id: "omp-\(file.lastPathComponent)", kind: .omp, title: title, account: nil,
                                      project: URL(fileURLWithPath: String(lines[0])).lastPathComponent, state: state, pid: pid))
        }
        return found.sorted { $0.id < $1.id }
    }

    nonisolated private static func tailLines(of url: URL, bytes: UInt64) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > bytes ? size - bytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return start > 0 ? Array(lines.dropFirst()) : lines
    }

    nonisolated static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Niche could not run %@: %@", tool, String(describing: error))
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct AgentGlyph: View {
    let kind: AgentKind
    let size: CGFloat

    var body: some View {
        switch kind {
        case .claude:
            Image(systemName: "staroflife.fill")
                .font(.system(size: size * 0.82, weight: .bold))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: size, height: size)
        case .omp:
            Text("π")
                .font(.system(size: size + 3, weight: .heavy, design: .serif))
                .foregroundStyle(Color(red: 0.55, green: 0.76, blue: 1))
                .frame(width: size, height: size)
        }
    }
}

struct StatusDot: View {
    let working: Bool

    var body: some View {
        Circle()
            .fill(working ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(.black, lineWidth: 1.5))
            .phaseAnimator(working ? [1.0, 0.3] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

struct AgentIndicator: View {
    let kind: AgentKind
    let sessions: [AgentSession]

    var body: some View {
        AgentGlyph(kind: kind, size: 13)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(working: sessions.contains { $0.state == .working })
                    .offset(x: 4, y: 2)
            }
    }
}

struct AgentSessionList: View {
    let sessions: [AgentSession]
    let showsAll: Bool
    let onToggleAll: () -> Void
    let onSelect: (AgentSession) -> Void
    static let visibleRows = 4
    static let rowHeight: CGFloat = 22
    static let spacing: CGFloat = 4
    static let moreHeight: CGFloat = 12

    var body: some View {
        VStack(spacing: Self.spacing) {
            ForEach(sessions.prefix(showsAll ? sessions.count : Self.visibleRows)) { session in
                AgentSessionRow(session: session) { onSelect(session) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if sessions.count > Self.visibleRows {
                MoreButton(title: showsAll ? "Show less" : "+\(sessions.count - Self.visibleRows) more", action: onToggleAll)
                    .frame(height: Self.moreHeight)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct MoreButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(isHovered ? 0.8 : 0.45))
                .contentTransition(.interpolate)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct AgentSessionRow: View {
    let session: AgentSession
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let working = session.state == .working
        let title = session.title ?? session.project
        let detail = ([title == session.project ? nil : session.project, session.account] as [String?]).compactMap { $0 }
        Button(action: action) {
            HStack(spacing: 8) {
                AgentIndicator(kind: session.kind, sessions: [session])
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                Text(working ? "Working" : "Paused")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(working ? Color.green : .white.opacity(0.45))
                    .fixedSize()
            }
            .padding(.horizontal, 9)
            .frame(height: AgentSessionList.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isHovered ? 0.12 : 0.04)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct AgentClosedView: View {
    let monitor: AgentMonitor
    let art: IdleArt?
    @State private var lastSessions: [AgentSession] = []

    var body: some View {
        let sessions = monitor.isEmpty ? (art == nil ? lastSessions : []) : monitor.sessions
        let live = AgentKind.allCases.filter { kind in sessions.contains { $0.kind == kind } }
        let working = sessions.filter { $0.state == .working }.count
        let count = Text("\(working > 0 ? working : sessions.count)")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.numericText())
        HStack(spacing: 0) {
            if let art {
                IdleArtView(art: art, size: 24, cornerRadius: 7)
                    .offset(y: -1)
                    .padding(.leading, 5)
                    .frame(width: MusicClosedView.slot, alignment: .leading)
                    .transition(.opacity)
                Spacer(minLength: 0)
                if !sessions.isEmpty {
                    HStack(spacing: 7) {
                        HStack(spacing: 9) {
                            ForEach(live, id: \.self) { kind in
                                AgentIndicator(kind: kind, sessions: sessions.filter { $0.kind == kind })
                                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                            }
                        }
                        count
                    }
                    .padding(.trailing, 9)
                    .offset(y: -2)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(live, id: \.self) { kind in
                        AgentGlyph(kind: kind, size: 14)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .padding(.leading, 10)
                .offset(y: -2)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    StatusDot(working: working > 0)
                    count
                }
                .padding(.trailing, 10)
                .offset(y: -2)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: live)
        .onAppear { lastSessions = monitor.sessions }
        .onChange(of: monitor.sessions) { _, sessions in
            if !sessions.isEmpty { lastSessions = sessions }
        }
    }
}
