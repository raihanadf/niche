import Foundation

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int, time: Double, end: Double, text: String, charTimings: [Double]
    init(id: Int, time: Double, end: Double, text: String, charTimings: [Double] = []) {
        self.id = id; self.time = time; self.end = end; self.text = text; self.charTimings = charTimings
    }
}

enum LyricsParser {
    private static let creditPatterns = [
        "作词", "作曲", "编曲", "制作人", "监制", "录音", "混音", "母带",
        "written by", "lyrics by", "composed by", "produced by", "arranged by"
    ]
    private static let vowels = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüýÿ")

    static func syllableCount(_ word: String) -> Int {
        var count = 0, inVowel = false
        for ch in word.lowercased() {
            if vowels.contains(ch) {
                if !inVowel { count += 1; inVowel = true }
            } else { inVowel = false }
        }
        return max(1, count)
    }

    static func charTimings(text: String, start: Double, end: Double) -> [Double] {
        guard !text.isEmpty else { return [] }
        let duration = max(0.1, end - start)
        let words = text.components(separatedBy: " ")
        let syllables = words.map { $0.isEmpty ? 0 : syllableCount($0) }
        let totalSyllables = max(1, syllables.reduce(0, +))
        var timings: [Double] = [], currentT = start
        timings.reserveCapacity(text.count)
        for (i, word) in words.enumerated() {
            let wordDur = duration * (Double(syllables[i]) / Double(totalSyllables))
            let charDur = word.isEmpty ? 0 : wordDur / Double(word.count)
            for _ in word { timings.append(currentT); currentT += charDur }
            if i < words.count - 1 { timings.append(currentT) }
        }
        return timings
    }

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
            let text = rest.replacing(#/<\d+:\d+([.:]\d+)?>/#, with: "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !isCreditLine(text, times: times) {
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
            let duration: Double = gap <= 6.0
                ? max(0.5, gap - min(0.4, gap * 0.12))
                : min(gap - 0.5, max(3.0, min(8.0, words * 0.45 + chars * 0.06 + 1.0)))
            let end = max(time + 0.5, time + duration)
            return LyricLine(id: i, time: time, end: end, text: text, charTimings: charTimings(text: text, start: time, end: end))
        }
    }

    static func parsePlain(_ plain: String) -> [LyricLine] {
        plain.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: 0, end: 0, text: $0.element, charTimings: []) }
    }

    private static func isCreditLine(_ text: String, times: [Double]) -> Bool {
        guard let firstTime = times.first, firstTime <= 3.0 else { return false }
        let lower = text.lowercased()
        return creditPatterns.contains { lower.contains($0) }
    }
}
