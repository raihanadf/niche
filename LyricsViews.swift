import AppKit
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
                        .animation(.arrive, value: focusKey)
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
        .animation(.arrive, value: role)
        .animation(.arrive, value: isTrailing)
        .animation(.arrive, value: distance)
        .onHover { inside in withAnimation(.hover) { isHovered = inside } }
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

struct ClosedLyric: NSViewRepresentable {
    let player: MusicPlayer
    let text: String
    let twoRows: Bool

    func makeNSView(context: Context) -> KaraokeView { KaraokeView() }

    func updateNSView(_ view: KaraokeView, context: Context) {
        let lyrics = player.lyrics
        let timings = lyrics.isKaraoke ? lyrics.activeLine.flatMap { $0.text == text ? $0.charTimings : nil } : nil
        view.update(text: text, timings: timings, twoRows: twoRows,
                    time: player.currentPosition - lyrics.delay, isPlaying: player.isPlaying)
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
            let originX = ((bounds.width - width) / 2).rounded()
            let bandY = top - lineHeight * CGFloat(index + 1)
            context.textPosition = CGPoint(x: originX, y: bandY - font.descender)
            CTLineDraw(entry.line, context)
            guard let timings else { continue }
            let end = entry.range.location + entry.range.length
            var keys: [(time: Double, x: CGFloat)] = []
            var step = 0.1
            for (char, start) in starts.enumerated() where start >= entry.range.location && start < end {
                let left = originX + CTLineGetOffsetForStringIndex(entry.line, start, nil)
                if let previous = keys.last {
                    step = min(max(timings[char] - previous.time, 0.05), 0.3)
                } else {
                    keys.append((timings[char] - 0.05, left - Self.soft / 2))
                }
                keys.append((timings[char], left))
            }
            guard let last = keys.last else { continue }
            keys.append((last.time + step, originX + width + Self.soft / 2))
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
