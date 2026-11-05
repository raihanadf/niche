import CryptoKit
import Foundation
import SwiftUI

struct UsageWindow: Equatable {
    let label: String
    let used: Double
    let resetsAt: Date?
}

struct UsageAccount: Identifiable, Equatable {
    let id: String
    let kind: AgentKind
    let name: String
    let detail: String?
    let windows: [UsageWindow]
}

@MainActor
@Observable
final class AgentUsage {
    private(set) var accounts: [UsageAccount] = []
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var kinds: Set<AgentKind> = []

    func refresh(kinds: Set<AgentKind>) {
        if kinds == self.kinds, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 300 { return }
        self.kinds = kinds
        fetchedAt = Date()
        Task {
            var fresh = kinds.contains(.claude) ? await Self.claudeAccounts() : []
            if kinds.contains(.omp) { fresh += await Self.ompAccounts() }
            let kept = accounts.filter { old in kinds.contains(old.kind) && !fresh.contains { $0.id == old.id } }
            let merged = (fresh + kept).sorted { ($0.kind == .omp ? 1 : 0, $0.id) < ($1.kind == .omp ? 1 : 0, $1.id) }
            guard merged != accounts else { return }
            withAnimation(.arrive) { accounts = merged }
        }
    }

    nonisolated private static func claudeAccounts() async -> [UsageAccount] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: fm.homeDirectoryForCurrentUser, includingPropertiesForKeys: nil) else { return [] }
        var found: [UsageAccount] = []
        for config in entries where config.lastPathComponent.hasPrefix(".claude") && config.hasDirectoryPath {
            let folder = config.lastPathComponent
            let hash = SHA256.hash(data: Data(config.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
            let service = folder == ".claude" ? "Claude Code-credentials" : "Claude Code-credentials-\(hash)"
            let raw = AgentMonitor.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            guard let stored = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let oauth = stored["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else { continue }
            if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 {
                NSLog("Niche skipped %@ usage, its login has expired", folder)
                continue
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let five = window("5h", usage["five_hour"]), let seven = window("7d", usage["seven_day"]) else {
                NSLog("Niche could not fetch %@ usage", folder)
                continue
            }
            let suffix = folder.dropFirst(".claude".count).drop { $0 == "-" }
            found.append(UsageAccount(id: "claude-\(folder)", kind: .claude, name: suffix.isEmpty ? "claude" : String(suffix),
                                      detail: nil, windows: [five, seven]))
        }
        return found

        func window(_ label: String, _ value: Any?) -> UsageWindow? {
            guard let entry = value as? [String: Any], let used = entry["utilization"] as? Double else { return nil }
            let reset = (entry["resets_at"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
            }
            return UsageWindow(label: label, used: used / 100, resetsAt: reset)
        }
    }

    nonisolated private static func ompAccounts() async -> [UsageAccount] {
        let db = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omp/agent/agent.db").path
        let query = """
            select u.provider, u.limit_id, u.label, u.window_label, u.used_fraction, u.resets_at from usage_history u
            join (select max(id) id from usage_history group by account_key, limit_id) latest on latest.id = u.id
            where u.used_fraction is not null and u.window_label is not null and u.resets_at > 0
              and exists (select 1 from auth_credentials a where a.provider = u.provider and a.disabled_cause is null
                          and instr(u.account_key, a.identity_key) > 0)
            """
        let output = AgentMonitor.run("/usr/bin/sqlite3", ["-readonly", "-json", db, query])
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        let now = Date()
        var cards: [String: (name: String, detail: String?, windows: [String: (span: Int, entries: [(used: Double, reset: Date)])])] = [:]
        for row in rows {
            guard let provider = row["provider"] as? String, let limit = row["limit_id"] as? String, let label = row["label"] as? String,
                  let windowLabel = row["window_label"] as? String, let used = row["used_fraction"] as? Double,
                  let resetsAt = row["resets_at"] as? Double, let span = span(of: windowLabel) else { continue }
            let card: (name: String, detail: String?)
            switch provider {
            case "anthropic":
                guard limit == "anthropic:5h" || limit == "anthropic:7d" else { continue }
                card = ("claude", nil)
            case "google-antigravity": card = (label.replacingOccurrences(of: " (shared)", with: "").lowercased(), "antigravity")
            case "openai-codex": card = ("codex", nil)
            default: card = (provider, nil)
            }
            let id = "omp-\(provider)-\(card.name)"
            let reset = Date(timeIntervalSince1970: resetsAt / 1000)
            cards[id, default: (card.name, card.detail, [:])].windows[span.label, default: (span.seconds, [])].entries.append((used, reset))
        }
        return cards.map { id, card in
            let windows = card.windows.sorted { $0.value.span < $1.value.span }.map { label, window in
                let used = window.entries.map { $0.reset < now ? 0 : $0.used }.reduce(0, +) / Double(window.entries.count)
                return UsageWindow(label: label, used: used, resetsAt: window.entries.map(\.reset).filter { $0 > now }.min())
            }
            return UsageAccount(id: id, kind: .omp, name: card.name, detail: card.detail, windows: windows)
        }

        func span(of window: String) -> (label: String, seconds: Int)? {
            switch window.lowercased() {
            case "daily": return ("1d", 86_400)
            case "weekly": return ("7d", 604_800)
            default:
                let parts = window.lowercased().split(separator: " ")
                guard parts.count == 2, let count = Int(parts[0]) else { return nil }
                if parts[1].hasPrefix("hour") { return ("\(count)h", count * 3_600) }
                if parts[1].hasPrefix("day") { return ("\(count)d", count * 86_400) }
                return nil
            }
        }
    }
}

struct UsageStrip: View {
    let accounts: [UsageAccount]
    let room: CGFloat
    @State private var hovered: String?

    static let height: CGFloat = 56 + 12 + 24

    var body: some View {
        let idle = accounts.filter(\.isIdle)
        let folds = idle.count > 1
        let shown = folds ? accounts.filter { !$0.isIdle } : accounts
        VStack(alignment: .leading, spacing: 12) {
            hero(idle: idle)
            ViewThatFits(in: .horizontal) {
                chips(shown, idle: folds ? idle : [], named: true, percent: true)
                chips(shown, idle: folds ? idle : [], named: true, percent: false)
                chips(shown, idle: folds ? idle : [], named: false, percent: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height, alignment: .top)
    }

    private var tightest: UsageAccount? {
        accounts.max { $0.peak < $1.peak }
    }

    private func hero(idle: [UsageAccount]) -> some View {
        let focus = hovered == "idle" ? nil : accounts.first { $0.id == hovered } ?? tightest
        let key = hovered ?? "tightest"
        return HStack(spacing: 14) {
            ZStack {
                if let focus {
                    UsageRing(account: focus, lineWidth: 6, gap: 8.5)
                    AgentGlyph(kind: focus.kind, size: 13)
                        .id(focus.kind)
                        .transition(.blurReplace)
                } else {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 6).padding(3)
                    Text("+\(idle.count)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 1) {
                ZStack(alignment: .leading) {
                    Text(focus.map(\.title) ?? "under 5%")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .id(key)
                        .transition(.blurReplace(.downUp))
                }
                .frame(height: 17)
                ZStack(alignment: .leading) {
                    Group {
                        if let focus {
                            Text(Self.windows(focus)) + Text(Self.reset(focus).map { "  ·  resets in \($0)" } ?? "").foregroundStyle(.white.opacity(0.32))
                        } else {
                            Text(idle.map(\.name).joined(separator: ", "))
                        }
                    }
                    .font(.system(size: 12.5, weight: .regular).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .id(key)
                    .transition(.blurReplace(.downUp))
                }
                .frame(height: 16)
            }
            .padding(.top, max(LabState.hardwareNotch.height + 2 - 18 - room, 0))
            .frame(maxHeight: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .animation(.arrive, value: key)
    }

    private func chips(_ shown: [UsageAccount], idle: [UsageAccount], named: Bool, percent: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(shown) { account in
                UsageChip(isHovered: hovered == account.id) {
                    UsageRing(account: account, lineWidth: 2.4, gap: 4.2)
                        .padding(1.2)
                        .frame(width: 18, height: 18)
                    if named {
                        Text(account.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if percent {
                        Text("\(Int((account.peak * 100).rounded()))%")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(UsageRing.tint(account.kind, account.peak))
                            .fixedSize()
                    }
                }
                .onHover { hover(account.id, $0) }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if !idle.isEmpty {
                UsageChip(isHovered: hovered == "idle") {
                    Text("+\(idle.count) low")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize()
                        .padding(.leading, 5)
                }
                .onHover { hover("idle", $0) }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    private func hover(_ id: String, _ inside: Bool) {
        if inside {
            hovered = id
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(0.12))
            if hovered == id { hovered = nil }
        }
    }

    private static func windows(_ account: UsageAccount) -> String {
        account.windows.map { "\($0.label) \(Int(($0.used * 100).rounded()))%" }.joined(separator: "  ·  ")
    }

    private static func reset(_ account: UsageAccount) -> String? {
        guard let window = account.windows.max(by: { $0.used < $1.used }), window.used >= 0.005, let date = window.resetsAt else { return nil }
        let minutes = Int(max(date.timeIntervalSinceNow, 0) / 60)
        let left = minutes >= 1440 ? "\(minutes / 1440)d" : minutes >= 60 ? "\(minutes / 60)h" : "\(max(minutes, 1))m"
        return account.windows.count > 1 ? "\(left) (\(window.label))" : left
    }
}

private extension UsageAccount {
    var peak: Double { windows.reduce(0) { max($0, $1.used) } }
    var isIdle: Bool { peak < 0.05 }
    var title: String {
        let base = kind == .omp ? "omp \(name)" : name
        return detail.map { "\(base) (\($0))" } ?? base
    }
}

private struct UsageChip<Content: View>: View {
    let isHovered: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 5) { content }
            .padding(.leading, 3)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(isHovered ? 0.13 : 0.06)))
            .animation(.hover, value: isHovered)
    }
}

private struct UsageRing: View {
    let account: UsageAccount
    let lineWidth: CGFloat
    let gap: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(account.windows.reversed().enumerated()), id: \.offset) { index, window in
                let used = min(max(window.used, 0), 1)
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: lineWidth)
                    .padding(CGFloat(index) * gap)
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(Self.tint(account.kind, used), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(CGFloat(index) * gap)
            }
        }
        .padding(lineWidth / 2)
    }

    static func tint(_ kind: AgentKind, _ used: Double) -> Color {
        if used >= 0.85 { return Color(red: 1, green: 0.36, blue: 0.3) }
        return kind == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.55, green: 0.76, blue: 1)
    }
}
