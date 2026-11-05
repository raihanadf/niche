import AppKit
import SwiftUI

struct LyricsView: View {
    let player: MusicPlayer
    let track: Track
    static let height: CGFloat = 140
    private static let mask = LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        Group {
            switch player.lyrics.state {
            case .idle, .loading:
                LyricsSkeleton()
            case .missing:
                Text("No lyrics for this song")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let lines, let synced):
                let active = synced ? player.lyrics.index ?? 0 : min(Int(player.position / max(track.duration, 1) * Double(lines.count)), lines.count - 1)
                rows(lines, active: active, synced: synced)
                    .offset(y: Self.height * 0.38 - 19 - CGFloat(active) * 44)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: active)
                    .frame(height: Self.height, alignment: .top)
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.28), value: player.lyrics.state)
        .frame(height: Self.height)
        .clipped()
        .mask(Self.mask)
    }

    private func rows(_ lines: [LyricLine], active: Int, synced: Bool) -> some View {
        let start = max(0, active - 4)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(lines[start...min(lines.count - 1, active + 4)]) { line in
                LyricRow(
                    text: line.text.isEmpty ? "♪" : line.text,
                    isActive: synced && line.id == active && player.lyrics.isSinging,
                    distance: synced ? min(abs(line.id - active), 4) : 0
                ) {
                    guard synced, track.duration > 0 else { return }
                    let target = max(0, min(track.duration, line.time))
                    player.seek(to: target / track.duration)
                }
            }
        }
        .padding(.top, CGFloat(start) * 44)
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
    let isActive: Bool
    let distance: Int
    let seek: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: seek) {
            Text(text)
                .font(.system(size: isActive ? 14.5 : 13, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(opacity))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 38)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(isHovered && !isActive ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isActive)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: distance)
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { isHovered = inside } }
    }

    private var opacity: Double {
        isActive ? 1 : (isHovered ? 0.85 : [0.55, 0.42, 0.2, 0.08][min(distance, 3)])
    }
}

struct ClosedKaraokeLyricsView: View {
    let player: MusicPlayer
    let line: String
    let twoRows: Bool

    var body: some View {
        content
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .multilineTextAlignment(twoRows ? .leading : .center)
            .lineLimit(twoRows ? 2 : 1)
            .minimumScaleFactor(0.70)
            .overlay {
                ScrollAdjustOverlay { delta in
                    player.lyrics.adjustOffset(by: delta)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if line == "♪" {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.40 + 0.45 * (sin(time * 3.0) * 0.5 + 0.5)
                let opacity = player.isPlaying ? pulse : 0.55
                Text("♪")
                    .foregroundStyle(.white.opacity(opacity))
            }
        } else if let activeLine = player.lyrics.activeLine, activeLine.text == line {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                let pos = player.currentPosition + player.lyrics.lead + player.lyrics.offset
                Text(sweptText(line: activeLine, currentTime: pos))
            }
        } else {
            Text(line)
                .foregroundStyle(.white)
        }
    }

    private func sweptText(line: LyricLine, currentTime: Double) -> AttributedString {
        var str = AttributedString(line.text)
        let indices = Array(str.characters.indices), count = indices.count
        guard count > 0, count == line.charTimings.count else { return str }
        let sweepLead = 0.08, radius = 0.16, window = 2.0 * radius
        for i in 0..<count {
            let dist = (currentTime + sweepLead - line.charTimings[i]) + window
            let alpha = dist >= window ? 1.0 : (dist <= 0 ? 0.30 : 0.30 + 0.70 * (dist / window))
            let start = indices[i], end = str.characters.index(after: start)
            str[start..<end].foregroundColor = NSColor.white.withAlphaComponent(alpha)
        }
        return str
    }
}

private struct ScrollAdjustOverlay: NSViewRepresentable {
    let onScroll: (Double) -> Void

    func makeNSView(context: Context) -> ScrollCatcherView {
        let view = ScrollCatcherView(); view.onScroll = onScroll; return view
    }
    func updateNSView(_ nsView: ScrollCatcherView, context: Context) { nsView.onScroll = onScroll }

    final class ScrollCatcherView: NSView {
        var onScroll: ((Double) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
            let d = abs(dy) >= abs(dx) ? dy : dx
            guard abs(d) > 0.001 else { return }
            let scale = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
            onScroll?(Double(d) * scale)
        }
        override func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
        override func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
        override func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    }
}
