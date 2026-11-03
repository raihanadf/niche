import Foundation

struct LyricWord: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let time: Double
    let end: Double
}

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let end: Double
    let text: String
    let words: [LyricWord]

    init(id: Int, time: Double, end: Double, text: String, words: [LyricWord] = []) {
        self.id = id
        self.time = time
        self.end = end
        self.text = text
        self.words = words.isEmpty && end > time ? LyricsParser.naturalWords(for: text, time: time, end: end) : words
    }
}

enum LyricsParser {
    private static let creditPatterns: [String] = [
        "作词", "作曲", "编曲", "制作人", "监制", "录音", "混音", "母带",
        "written by", "lyrics by", "composed by", "produced by", "arranged by"
    ]

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var stamps: [(time: Double, text: String, raw: String)] = []
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
            let rawRest = String(rest)
            let text = rawRest.replacing(#/<\d+:\d+([.:]\d+)?>/#, with: "")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !isCreditLine(text, times: times) {
                stamps += times.map { ($0, text, rawRest) }
            }
        }

        stamps = stamps.map { (max(0, $0.time - offset), $0.text, $0.raw) }
        stamps.sort { $0.time < $1.time }
        return stamps.indices.map { i in
            let (time, text, raw) = stamps[i]
            let next = i + 1 < stamps.count ? stamps[i + 1].time : time + 6.0
            let sung = max(2.0, Double(text.split(separator: " ").count) * 0.45 + 1.2)
            let end = max(next - time > sung + 2.0 ? time + sung : next, time + 1.0)
            let parsedWords = parseInlineWords(rest: raw, lineTime: time, lineEnd: end, offset: offset)
            let words = parsedWords.isEmpty ? naturalWords(for: text, time: time, end: end) : parsedWords
            return LyricLine(id: i, time: time, end: end, text: text, words: words)
        }
    }

    static func splitWords(_ text: String) -> [String] {
        if text.contains(where: \.isWhitespace) {
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let chars = text.map(String.init)
        let hasCJK = chars.contains {
            $0.range(of: "\\p{Han}|\\p{Hiragana}|\\p{Katakana}|\\p{Hangul}", options: .regularExpression) != nil
        }
        if hasCJK {
            return chars.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return [text]
    }

    static func naturalWords(for text: String, time: Double, end: Double) -> [LyricWord] {
        let rawTokens = splitWords(text)
        guard !rawTokens.isEmpty else { return [] }
        let totalLen = max(1, rawTokens.reduce(0) { $0 + max(1, $1.count) })
        let totalDuration = max(0.6, end - time)
        var accum = 0.0
        var words: [LyricWord] = []
        words.reserveCapacity(rawTokens.count)
        for (i, word) in rawTokens.enumerated() {
            let wordLen = max(1, word.count)
            let wordDuration = totalDuration * (Double(wordLen) / Double(totalLen))
            let wordStart = time + accum
            let wordEnd = wordStart + wordDuration
            accum += wordDuration
            words.append(LyricWord(id: i, text: word, time: wordStart, end: wordEnd))
        }
        return words
    }

    static func parseInlineWords(rest: String, lineTime: Double, lineEnd: Double, offset: Double) -> [LyricWord] {
        let matches = Array(rest.matches(of: #/<(\d+:\d+(?:[.:]\d+)?)>/#))
        guard !matches.isEmpty else { return [] }

        var rawSegments: [(time: Double, text: String)] = []
        var lastIdx = rest.startIndex
        var currentTime = lineTime
        var trailingTime: Double?

        for match in matches {
            let textChunk = String(rest[lastIdx..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !textChunk.isEmpty {
                rawSegments.append((time: currentTime, text: textChunk))
            }
            if let ts = parseTimestamp(match.output.1) {
                currentTime = max(0, ts - offset)
                trailingTime = currentTime
            }
            lastIdx = match.range.upperBound
        }
        let suffixText = String(rest[lastIdx...]).trimmingCharacters(in: .whitespaces)
        if !suffixText.isEmpty {
            rawSegments.append((time: currentTime, text: suffixText))
            trailingTime = nil
        }
        guard !rawSegments.isEmpty else { return [] }

        var words: [LyricWord] = []
        for (i, seg) in rawSegments.enumerated() {
            let nextTime = (i + 1 < rawSegments.count) ? rawSegments[i + 1].time : (trailingTime ?? lineEnd)
            let subWords = splitWords(seg.text)
            if subWords.count <= 1 {
                let end = max(seg.time + 0.1, nextTime)
                words.append(LyricWord(id: words.count, text: seg.text, time: seg.time, end: end))
            } else {
                let totalLen = max(1, subWords.reduce(0) { $0 + max(1, $1.count) })
                let dur = max(0.2, nextTime - seg.time)
                var accum = 0.0
                for sw in subWords {
                    let wDur = dur * (Double(max(1, sw.count)) / Double(totalLen))
                    let wStart = seg.time + accum
                    let wEnd = wStart + wDur
                    accum += wDur
                    words.append(LyricWord(id: words.count, text: sw, time: wStart, end: wEnd))
                }
            }
        }
        return words
    }

    private static func parseTimestamp(_ raw: Substring) -> Double? {
        let parts = raw.split(separator: ":")
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            return numbers[0] * 60 + numbers[1]
        } else if numbers.count == 3 {
            return numbers[0] * 60 + numbers[1] + (numbers[2] / 100.0)
        }
        return nil
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
