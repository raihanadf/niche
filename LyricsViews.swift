import SwiftUI

struct LyricsView: View {
    let player: MusicPlayer
    let track: Track
    static let height: CGFloat = 140
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 4
    static var rowStride: CGFloat { rowHeight + rowSpacing }
    private static let mask = LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom
    )

    struct PlanRow: Identifiable {
        let index: Int
        let line: LyricLine
        var id: Int { index }
    }

    struct DisplayPlan {
        let rows: [PlanRow]
        let start: Int
        let activeSlot: Int
        let offsetY: CGFloat
    }

    enum RowRole: Equatable {
        case inactive, primary, secondaryDuet, secondaryOverlap, backgroundActive
    }

    var body: some View {
        Group {
            switch player.lyrics.state {
            case .idle, .loading:
                LyricsSkeleton()
            case .missing:
                missingView
            case .loaded(let lines, let synced):
                if lines.isEmpty {
                    missingView
                } else {
                    let active = synced
                        ? min(player.lyrics.index ?? 0, lines.count - 1)
                        : min(max(0, Int(player.position / max(track.duration, 1) * Double(lines.count))), lines.count - 1)
                    let secondary = synced && player.lyrics.isSinging
                        ? player.lyrics.secondaryIndex.flatMap { $0 >= 0 && $0 < lines.count && $0 != active ? $0 : nil }
                        : nil
                    let plan = Self.displayPlan(lines: lines, active: active, secondary: secondary)
                    let focusKey = "\(active):\(secondary ?? -1)"
                    rows(plan: plan, allLines: lines, active: active, secondary: secondary, synced: synced)
                        .id("\(player.songChangeToken)-\(player.lyrics.loadToken)")
                        .offset(y: plan.offsetY)
                        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: focusKey)
                        .frame(height: Self.height, alignment: .top)
                }
            }
        }
        .transition(.blurReplace)
        .animation(.fadeIn, value: player.lyrics.state)
        .frame(height: Self.height)
        .clipped()
        .mask(Self.mask)
    }

    private var missingView: some View {
        Text("No lyrics for this song")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func displayPlan(lines: [LyricLine], active: Int, secondary: Int?) -> DisplayPlan {
        guard !lines.isEmpty else { return DisplayPlan(rows: [], start: 0, activeSlot: 0, offsetY: 0) }
        let clampedActive = max(0, min(active, lines.count - 1))
        let sec = secondary.flatMap { $0 >= 0 && $0 < lines.count && $0 != clampedActive ? $0 : nil }
        let start = max(0, clampedActive - 4)
        let end = min(lines.count - 1, clampedActive + 4)
        var window = (start...end).map { PlanRow(index: $0, line: lines[$0]) }
        if let sec, abs(sec - clampedActive) > 1 {
            window.removeAll { $0.index == sec }
            if let pos = window.firstIndex(where: { $0.index == clampedActive }) {
                window.insert(PlanRow(index: sec, line: lines[sec]), at: sec < clampedActive ? pos : pos + 1)
            }
        }
        let activePos = window.firstIndex(where: { $0.index == clampedActive }) ?? 0
        let activeSlot = start + activePos
        let offsetY: CGFloat
        if let sec {
            let pairTop = (height - (rowHeight * 2 + rowSpacing)) / 2
            let topSlot = sec < clampedActive ? activeSlot - 1 : activeSlot
            offsetY = pairTop - CGFloat(topSlot) * rowStride
        } else {
            offsetY = height * 0.38 - rowHeight / 2 - CGFloat(activeSlot) * rowStride
        }
        return DisplayPlan(rows: window, start: start, activeSlot: activeSlot, offsetY: offsetY)
    }

    static func isTrailingLine(_ item: PlanRow, leadAgent: String?, activeAgent: String?, secondaryIndex: Int?, isDuet: Bool) -> Bool {
        guard !item.line.isBackground, let agent = item.line.agent, let leadAgent else { return false }
        if isDuet, item.index == secondaryIndex, activeAgent != leadAgent { return false }
        return agent != leadAgent
    }

    private func rows(plan: DisplayPlan, allLines: [LyricLine], active: Int, secondary: Int?, synced: Bool) -> some View {
        let singing = synced && player.lyrics.isSinging
        let leadAgent = allLines.first { !$0.isBackground && $0.agent != nil }?.agent
        let activeAgent = allLines[active].agent
        let isDuet = player.lyrics.isDuet
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(plan.rows.enumerated()), id: \.element.id) { idx, item in
                let role: RowRole = if singing && item.index == active {
                    item.line.isBackground ? .backgroundActive : .primary
                } else if singing && item.index == secondary {
                    item.line.isBackground ? .backgroundActive : (isDuet ? .secondaryDuet : .secondaryOverlap)
                } else {
                    .inactive
                }
                let trailing = Self.isTrailingLine(item, leadAgent: leadAgent, activeAgent: activeAgent, secondaryIndex: secondary, isDuet: isDuet)
                LyricRow(
                    text: item.line.text.isEmpty ? "♪" : item.line.text,
                    role: role,
                    isBackground: item.line.isBackground,
                    isTrailing: trailing,
                    distance: synced ? min(abs((plan.start + idx) - plan.activeSlot), 4) : 0
                ) {
                    guard synced, track.duration > 0 else { return }
                    let target = max(0, min(track.duration, item.line.time))
                    player.seek(to: target / track.duration)
                }
            }
        }
        .padding(.top, CGFloat(plan.start) * Self.rowStride)
    }
}

private struct LyricsSkeleton: View {
    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar(width: 135, height: 13, opacity: isOn ? 0.14 : 0.05)
            bar(width: 185, height: 16, opacity: isOn ? 0.32 : 0.14)
            bar(width: 115, height: 13, opacity: isOn ? 0.14 : 0.05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { isOn = true } }
    }

    private func bar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: width, height: height)
    }
}

private struct LyricRow: View {
    let text: String
    let role: LyricsView.RowRole
    let isBackground: Bool
    let isTrailing: Bool
    let distance: Int
    let seek: () -> Void
    @State private var isHovered = false

    var body: some View {
        let active = role != .inactive
        let visual = style
        Button(action: seek) {
            Text(text)
                .font(.system(size: visual.size, weight: visual.weight, design: .rounded))
                .foregroundStyle(.white.opacity(visual.opacity))
                .multilineTextAlignment(isTrailing ? .trailing : .leading)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
                .frame(height: LyricsView.rowHeight)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(isHovered && !active ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: role)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isTrailing)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: distance)
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { isHovered = inside } }
    }

    private var style: (size: CGFloat, weight: Font.Weight, opacity: Double) {
        let bgAlpha = isBackground ? 0.75 : 1
        return switch role {
        case .primary: (14.5, .bold, 1.0)
        case .secondaryDuet: (14.0, .bold, 0.95)
        case .secondaryOverlap: (13.5, .semibold, 0.88)
        case .backgroundActive: (12.5, .semibold, 0.84)
        case .inactive: (isBackground ? 11.5 : 13.0, .medium, isHovered ? 0.85 : [0.55, 0.42, 0.2, 0.08][min(distance, 3)] * bgAlpha)
        }
    }
}
