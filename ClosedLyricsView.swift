import AppKit
import CoreText
import SwiftUI

struct ClosedKaraokeLyricsView: View {
    let player: MusicPlayer
    let line: String
    let activeLine: LyricLine?

    var body: some View {
        content
            .font(ClosedLyricsLayout.closedFont)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: ClosedLyricsLayout.singleFrameHeight)
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
                Text("♪").foregroundStyle(.white.opacity(opacity))
            }
        } else if let activeLine, activeLine.text == line, !activeLine.charTimings.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !player.isPlaying)) { _ in
                let pos = player.currentPosition + player.lyrics.lead + player.lyrics.offset
                Text(Self.sweptText(line: activeLine, currentTime: pos))
            }
        } else {
            Text(line).foregroundStyle(.white)
        }
    }

    static func sweptText(line: LyricLine, currentTime: Double) -> AttributedString {
        var str = AttributedString(line.text)
        let count = str.characters.count
        guard count > 0, !line.charTimings.isEmpty else { return str }
        let tCount = line.charTimings.count
        var stack: [Double] = []
        var cursor = str.characters.endIndex
        var runEnd = cursor
        var runAlpha: Double?
        for i in stride(from: count - 1, through: 0, by: -1) {
            let charStart = str.characters.index(before: cursor)
            let t = tCount == count ? line.charTimings[i] : line.charTimings[min(tCount - 1, Int(Double(i) * Double(tCount) / Double(count)))]
            while let top = stack.last, top <= t { stack.removeLast() }
            let alpha: Double
            if currentTime <= t {
                alpha = 0.30
            } else {
                let nextT = stack.last ?? line.end
                let dur = max(0.04, min(0.24, nextT - t))
                alpha = currentTime >= t + dur ? 1.00 : 0.30 + 0.70 * ((currentTime - t) / dur)
            }
            stack.append(t)
            if let prev = runAlpha, abs(alpha - prev) > 1e-12 {
                str[cursor..<runEnd].foregroundColor = Color.white.opacity(prev)
                runEnd = cursor
                runAlpha = alpha
            } else if runAlpha == nil {
                runAlpha = alpha
            }
            cursor = charStart
        }
        if let finalAlpha = runAlpha {
            str[cursor..<runEnd].foregroundColor = Color.white.opacity(finalAlpha)
        }
        return str
    }
}

@MainActor
enum ClosedLyricsLayout {
    struct Metrics: Equatable {
        let textHeight: CGFloat
        let isTwoLines: Bool
        static let empty = Metrics(textHeight: 0, isTwoLines: false)
    }

    static let closedFont = Font.system(size: 11.5, weight: .semibold, design: .rounded)
    static let closedNSFont = Lyrics.closedFont
    private static let scaledNSFont = Lyrics.closedNSFont(size: 11.5 * 0.85)
    static let singleShelfHeight: CGFloat = 22
    static let singleFrameHeight: CGFloat = 20
    static let twoLineMinHeight: CGFloat = 36
    static let verticalPadding: CGFloat = 8
    static let maxIslandMiddle: CGFloat = 224
    static let shelfHorizontalPadding: CGFloat = 14
    static let islandHorizontalPadding: CGFloat = 4
    private static let twoLineThreshold: CGFloat = 21
    private static var cached: (text: String, width: CGFloat, metrics: Metrics)?

    static func islandHalfRoom(lineWidth: CGFloat, notchWidth: CGFloat) -> CGFloat {
        guard lineWidth > 0 else { return 0 }
        let middle = min(ceil(lineWidth) + 12, maxIslandMiddle)
        return ceil(max(0, middle - notchWidth) / 2)
    }

    static func availableWidth(usesShelf: Bool, closedWidth: CGFloat, notchWidth: CGFloat, islandHalfRoom: CGFloat) -> CGFloat {
        if usesShelf {
            return max(0, closedWidth - 2 * shelfHorizontalPadding)
        }
        return max(0, notchWidth + 2 * islandHalfRoom - 2 * islandHorizontalPadding)
    }

    static func metrics(for text: String, width: CGFloat) -> Metrics {
        guard !text.isEmpty, width > 0 else { return .empty }
        if text == "♪" { return Metrics(textHeight: 14, isTwoLines: false) }
        if let cached, cached.text == text, cached.width == width {
            return cached.metrics
        }
        let base = measureCT(text, font: closedNSFont, width: width)
        let result: Metrics
        if base.lineCount <= 1 {
            result = Metrics(textHeight: base.height, isTwoLines: base.height > twoLineThreshold)
        } else if base.lineCount == 2 {
            result = Metrics(textHeight: base.height, isTwoLines: true)
        } else {
            let scaled = measureCT(text, font: scaledNSFont, width: width)
            result = Metrics(textHeight: scaled.twoLineHeight, isTwoLines: true)
        }
        cached = (text, width, result)
        return result
    }

    private static func measureCT(_ text: String, font: NSFont, width: CGFloat) -> (height: CGFloat, lineCount: Int, twoLineHeight: CGFloat) {
        let attr = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let constraint = CGSize(width: width, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: max(ceil(size.height) + 16, 256)), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        let twoLineHeight: CGFloat
        if lines.count > 2 {
            let second = CTLineGetStringRange(lines[1])
            let len = second.location + second.length
            twoLineHeight = ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: len), nil, constraint, nil).height)
        } else {
            twoLineHeight = ceil(size.height)
        }
        return (ceil(size.height), lines.count, twoLineHeight)
    }

    static func extraHeight(for metrics: Metrics, usesShelf: Bool, notchHeight: CGFloat) -> CGFloat {
        if usesShelf {
            guard metrics.textHeight > 0 else { return 0 }
            return metrics.isTwoLines ? max(twoLineMinHeight, metrics.textHeight + verticalPadding) : singleShelfHeight
        }
        guard metrics.isTwoLines else { return 0 }
        return max(0, max(twoLineMinHeight, metrics.textHeight + verticalPadding) - notchHeight)
    }

    static func lyricFrameHeight(for metrics: Metrics) -> CGFloat {
        metrics.isTwoLines ? max(singleFrameHeight, max(twoLineMinHeight, metrics.textHeight + verticalPadding) - 2) : singleFrameHeight
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
