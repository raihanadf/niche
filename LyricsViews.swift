import AppKit
import SwiftUI

struct LyricsView: View {
    let player: MusicPlayer
    let track: Track
    static let height: CGFloat = 140
    private static var mask: LinearGradient {
        let hidden = max(0, min(LabState.hardwareNotch.height, 32) - 18) / height
        return LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .clear, location: hidden), .init(color: .black, location: hidden + 0.16),
                    .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }

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
                    .animation(.arrive, value: active)
                    .frame(height: Self.height, alignment: .top)
            }
        }
        .transition(.blurReplace)
        .animation(.fadeIn, value: player.lyrics.state)
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
        .animation(.arrive, value: isActive)
        .animation(.arrive, value: distance)
        .onHover { inside in withAnimation(.hover) { isHovered = inside } }
    }

    private var opacity: Double {
        isActive ? 1 : (isHovered ? 0.85 : [0.55, 0.42, 0.2, 0.08][min(distance, 3)])
    }
}

struct ClosedLyric: NSViewRepresentable {
    let player: MusicPlayer
    let text: String
    let twoRows: Bool

    func makeNSView(context: Context) -> KaraokeView { KaraokeView() }

    func updateNSView(_ view: KaraokeView, context: Context) {
        let lyrics = player.lyrics
        let timings = lyrics.activeLine.flatMap { $0.text == text ? $0.charTimings : nil }
        view.update(text: text, timings: timings, twoRows: twoRows,
                    time: player.currentPosition + lyrics.lead, isPlaying: player.isPlaying)
    }
}

final class KaraokeView: NSView {
    private struct Row {
        let band: CGRect
        let keys: [(time: Double, x: CGFloat)]
    }

    private static let soft: CGFloat = 10
    private let dim = CALayer()
    private let lit = CALayer()
    private let sweep = CALayer()
    private var text = ""
    private var timings: [Double]?
    private var twoRows = false
    private var time = 0.0
    private var isPlaying = false
    private var rows: [Row] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dim.opacity = 0.3
        layer!.addSublayer(dim)
        layer!.addSublayer(lit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(text: String, timings: [Double]?, twoRows: Bool, time: Double, isPlaying: Bool) {
        let timings = timings.flatMap { $0.count == text.count ? $0 : nil }
        let changed = text != self.text || timings != self.timings || twoRows != self.twoRows
        self.text = text
        self.timings = timings
        self.twoRows = twoRows
        self.time = time
        self.isPlaying = isPlaying
        if changed { render() }
        animate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
        animate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
        animate()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        guard resized else { return }
        render()
        animate()
    }

    private func render() {
        guard let window, bounds.width > 0, bounds.height > 0, !text.isEmpty else { return }
        let maxRows = twoRows ? 2 : 1
        var size: CGFloat = 11.5
        var font = Lyrics.closedFont
        var lines: [(line: CTLine, range: CFRange)] = []
        repeat {
            font = NSFont(descriptor: Lyrics.closedFont.fontDescriptor, size: size)!
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let setter = CTTypesetterCreateWithAttributedString(string)
            lines = []
            var start = 0
            while start < string.length {
                let count = twoRows ? max(1, CTTypesetterSuggestLineBreak(setter, start, Double(bounds.width))) : string.length
                let range = CFRange(location: start, length: count)
                lines.append((CTTypesetterCreateLine(setter, range), range))
                start += count
            }
            size -= 0.25
        } while size >= 11.5 * 0.7 && (lines.count > maxRows || lines.contains { Self.width(of: $0.line) > bounds.width })

        let scale = window.backingScaleFactor
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let shown = lines.prefix(maxRows)
        let top = (bounds.height + lineHeight * CGFloat(shown.count)) / 2
        let context = CGContext(data: nil, width: Int(ceil(bounds.width * scale)), height: Int(ceil(bounds.height * scale)), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let utf16 = text.utf16
        let starts = text.indices.map { utf16.distance(from: utf16.startIndex, to: $0.samePosition(in: utf16)!) }
        rows = []
        for (index, entry) in shown.enumerated() {
            let width = Self.width(of: entry.line)
            let originX = twoRows ? 0 : ((bounds.width - width) / 2).rounded()
            let bandY = top - lineHeight * CGFloat(index + 1)
            context.textPosition = CGPoint(x: originX, y: bandY - font.descender)
            CTLineDraw(entry.line, context)
            guard let timings else { continue }
            let end = entry.range.location + entry.range.length
            var keys: [(time: Double, x: CGFloat)] = []
            for (char, start) in starts.enumerated() where start >= entry.range.location && start < end {
                let next = char + 1 < starts.count ? starts[char + 1] : utf16.count
                let left = CTLineGetOffsetForStringIndex(entry.line, start, nil)
                let right = CTLineGetOffsetForStringIndex(entry.line, min(next, end), nil)
                if keys.isEmpty { keys.append((timings[char] - 0.16, originX + left - Self.soft / 2)) }
                keys.append((timings[char] - 0.08, originX + (left + right) / 2))
            }
            guard let last = keys.last else { continue }
            keys.append((last.time + 0.08, originX + width + Self.soft / 2))
            rows.append(Row(band: CGRect(x: 0, y: bandY, width: bounds.width, height: lineHeight), keys: keys))
        }
        let image = context.makeImage()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [dim, lit] {
            layer.frame = bounds
            layer.contentsScale = scale
            layer.contents = image
        }
        dim.isHidden = timings == nil
        sweep.frame = bounds
        sweep.sublayers = rows.map { row in
            let edge = CAGradientLayer()
            edge.startPoint = CGPoint(x: 0, y: 0.5)
            edge.endPoint = CGPoint(x: 1, y: 0.5)
            edge.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
            edge.locations = [0, NSNumber(value: Double(bounds.width / (bounds.width + Self.soft))), 1]
            edge.bounds = CGRect(x: 0, y: 0, width: bounds.width + Self.soft, height: row.band.height)
            edge.position = CGPoint(x: row.keys[0].x - bounds.width / 2, y: row.band.midY)
            return edge
        }
        lit.mask = timings == nil ? nil : sweep
        CATransaction.commit()
    }

    private func animate() {
        if text == "♪" {
            lit.opacity = isPlaying ? 1 : 0.55
            guard isPlaying else {
                lit.removeAnimation(forKey: "pulse")
                return
            }
            guard lit.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.85
            pulse.toValue = 0.4
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            lit.add(pulse, forKey: "pulse")
            return
        }
        lit.removeAnimation(forKey: "pulse")
        lit.opacity = 1
        guard let edges = sweep.sublayers, edges.count == rows.count else { return }
        let now = CACurrentMediaTime()
        for (edge, row) in zip(edges, rows) {
            edge.removeAnimation(forKey: "sweep")
            let first = row.keys[0].time
            let span = max(row.keys[row.keys.count - 1].time - first, 0.01)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            edge.position.x = Self.edge(in: row.keys, at: time) - bounds.width / 2
            CATransaction.commit()
            guard isPlaying, time < first + span else { continue }
            let move = CAKeyframeAnimation(keyPath: "position.x")
            move.values = row.keys.map { $0.x - bounds.width / 2 }
            move.keyTimes = row.keys.map { NSNumber(value: ($0.time - first) / span) }
            move.duration = span
            move.beginTime = edge.convertTime(now, from: nil) + first - time
            move.fillMode = .both
            move.isRemovedOnCompletion = false
            edge.add(move, forKey: "sweep")
        }
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    private static func edge(in keys: [(time: Double, x: CGFloat)], at time: Double) -> CGFloat {
        guard let after = keys.firstIndex(where: { $0.time > time }) else { return keys[keys.count - 1].x }
        guard after > 0 else { return keys[0].x }
        let a = keys[after - 1], b = keys[after]
        return a.x + (b.x - a.x) * CGFloat((time - a.time) / (b.time - a.time))
    }
}
