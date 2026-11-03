import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let end: Double
    let text: String
}

enum LyricsParser {
    private static let creditPatterns: [String] = [
        "作词", "作曲", "编曲", "制作人", "监制", "录音", "混音", "母带",
        "written by", "lyrics by", "composed by", "produced by", "arranged by"
    ]

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
                    let seconds = numbers[0] * 60 + numbers[1] + (tag.count == 3 ? numbers[2] / 100.0 : 0)
                    times.append(seconds)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.replacing(#/<\d+:\d+([.:]\d+)?>/#, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !isCreditLine(text, times: times) {
                stamps += times.map { ($0, text) }
            }
        }

        stamps = stamps.map { (max(0, $0.time - offset), $0.text) }
        stamps.sort { $0.time < $1.time }
        return stamps.indices.map { i in
            let (time, text) = stamps[i]
            let next = i + 1 < stamps.count ? stamps[i + 1].time : time + 6.0
            let sung = max(2.0, Double(text.split(separator: " ").count) * 0.45 + 1.2)
            let end = max(next - time > sung + 2.0 ? time + sung : next, time + 1.0)
            return LyricLine(id: i, time: time, end: end, text: text)
        }
    }

    static func parsePlain(_ plain: String) -> [LyricLine] {
        let lines = plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.enumerated().map { i, text in
            LyricLine(id: i, time: 0, end: 0, text: text)
        }
    }

    private static func isCreditLine(_ text: String, times: [Double]) -> Bool {
        guard let firstTime = times.first, firstTime <= 3.0 else { return false }
        let lower = text.lowercased()
        return creditPatterns.contains { lower.contains($0) }
    }
}
