import Foundation

struct LyricLine: Identifiable, Equatable, Sendable, Codable {
    let id: Int, time: Double, end: Double, text: String, charTimings: [Double]
    let agent: String?
    let isBackground: Bool
    init(id: Int, time: Double, end: Double, text: String, charTimings: [Double] = [],
         agent: String? = nil, isBackground: Bool = false) {
        self.id = id; self.time = time; self.end = end; self.text = text
        self.charTimings = charTimings; self.agent = agent; self.isBackground = isBackground
    }
}

enum LyricsParser {
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var stamps: [(time: Double, text: String)] = []
        var offset = 0.0

        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = raw.drop { $0.isWhitespace }
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                let numbers = tag.compactMap { Double($0) }
                if tag.count == 2, tag[0].lowercased() == "offset", let ms = Double(tag[1]) {
                    offset = ms / 1000.0
                }
                if numbers.count == tag.count, (2...3).contains(tag.count) {
                    let divisor = tag.count == 3 ? pow(10.0, Double(tag[2].count)) : 1.0
                    let seconds = numbers[0] * 60 + numbers[1] + (tag.count == 3 ? numbers[2] / divisor : 0)
                    times.append(seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.replacing(#/<\d+:\d+([.:]\d+)?>/#, with: "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !LyricsWordParser.isMetadataOrJunkLine(text) {
                stamps += times.map { ($0, text) }
            }
        }

        stamps = stamps.map { (max(0, $0.time - offset), $0.text) }.sorted { $0.time < $1.time }
        return stamps.indices.map { i in
            let (time, text) = stamps[i]
            let words = Double(max(1, text.split(separator: " ").count))
            let chars = Double(max(1, text.count))
            let next = i + 1 < stamps.count ? stamps[i + 1].time : time + max(3.5, min(7.0, words * 0.45 + 1.2))
            let gap = max(0.6, next - time)
            let duration: Double = gap <= 5.0
                ? gap
                : min(gap - 1.5, max(3.5, min(8.0, words * 0.50 + chars * 0.06 + 1.5)))
            let end = max(time + 0.5, time + duration)
            return LyricLine(id: i, time: time, end: end, text: text, charTimings: [])
        }
    }

    static func parsePlain(_ plain: String) -> [LyricLine] {
        plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: 0, end: 0, text: $0.element, charTimings: []) }
    }
}
