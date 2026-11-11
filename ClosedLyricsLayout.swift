import AppKit
import CoreText

@MainActor
enum ClosedLyricsLayout {
    struct Metrics: Equatable {
        let textHeight: CGFloat
        let isTwoLines: Bool
        static let empty = Metrics(textHeight: 0, isTwoLines: false)
    }

    private static let scaledFont = NSFont(descriptor: Lyrics.closedFont.fontDescriptor, size: 11.5 * 0.85)!
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
        let base = measureCT(text, font: Lyrics.closedFont, width: width)
        let result: Metrics
        if base.lineCount <= 1 {
            result = Metrics(textHeight: base.height, isTwoLines: base.height > twoLineThreshold)
        } else if base.lineCount == 2 {
            result = Metrics(textHeight: base.height, isTwoLines: true)
        } else {
            let scaled = measureCT(text, font: scaledFont, width: width)
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
        let lines = CTFrameGetLines(frame) as! [CTLine]
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
