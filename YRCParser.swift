import Foundation

enum YRCParser {
    private static let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\](.*)$"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\((\d+),(-?\d+),(-?\d+)\)"#)

    static func parse(_ raw: String) -> [LyricLine]? {
        var entries: [(time: Double, naturalEnd: Double, text: String, charTimings: [Double])] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("{") else { continue }
            let fullRange = NSRange(line.startIndex..., in: line)
            guard let lineMatch = lineRegex.firstMatch(in: line, range: fullRange),
                  let msRange = Range(lineMatch.range(at: 1), in: line),
                  let durRange = Range(lineMatch.range(at: 2), in: line),
                  let bodyRange = Range(lineMatch.range(at: 3), in: line),
                  let ms = Double(line[msRange]), ms.isFinite, ms >= 0, ms < 86_400_000,
                  let durMs = Double(line[durRange]), durMs.isFinite, durMs >= 0, durMs < 86_400_000 else {
                continue
            }

            let lineStart = ms / 1000.0
            let lineDur = durMs / 1000.0
            let body = String(line[bodyRange])
            let bodyNSRange = NSRange(body.startIndex..., in: body)
            let tokenMatches = wordRegex.matches(in: body, range: bodyNSRange)
            guard !tokenMatches.isEmpty else { continue }

            var fullText = ""
            var words: [(start: Double, end: Double, text: String)] = []
            words.reserveCapacity(tokenMatches.count)

            for i in tokenMatches.indices {
                let match = tokenMatches[i]
                guard let tokRange = Range(match.range, in: body),
                      let wsRange = Range(match.range(at: 1), in: body),
                      let wdRange = Range(match.range(at: 2), in: body),
                      let wStartMs = Double(body[wsRange]), wStartMs.isFinite, wStartMs >= 0, wStartMs < 86_400_000,
                      let parsedWDurMs = Double(body[wdRange]), parsedWDurMs.isFinite, parsedWDurMs < 86_400_000 else {
                    continue
                }
                let wDurMs = max(10.0, parsedWDurMs)
                let sliceEnd = i + 1 < tokenMatches.count
                    ? (Range(tokenMatches[i + 1].range, in: body)?.lowerBound ?? body.endIndex)
                    : body.endIndex
                let slice = String(body[tokRange.upperBound..<sliceEnd])
                fullText += slice
                let wStart = wStartMs / 1000.0
                let wEnd = (wStartMs + wDurMs) / 1000.0
                words.append((start: wStart, end: wEnd, text: slice))
            }

            let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty,
                  !text.isEmpty,
                  !LyricsWordParser.isMetadataOrJunkLine(text),
                  !text.contains(#/^(?:作词|作詞|作曲|编曲|編曲|制作人|製作人|混音|母带|母帶|录音|錄音|和声|和聲|监制|監製|出品|词曲|詞曲|词\/曲|詞\/曲|原唱|演唱|词|詞|曲)\s*[:：]/#) else {
                continue
            }

            let charTimings = LyricsWordParser.wordTimingsToCharTimings(
                fullText: text,
                words: words,
                lineStart: lineStart
            )
            let wordsEnd = words.map(\.end).max() ?? lineStart
            let naturalEnd = lineDur > 0 ? max((ms + durMs) / 1000.0, wordsEnd) : wordsEnd
            entries.append((time: lineStart, naturalEnd: naturalEnd, text: text, charTimings: charTimings))
        }

        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.time < $1.time }
        let lines = sorted.indices.map { i in
            let item = sorted[i]
            let end: Double
            if i + 1 < sorted.count {
                let next = sorted[i + 1].time
                let gap = next - item.time
                if gap > 0 && gap <= 5.0 {
                    end = min(item.naturalEnd > item.time ? item.naturalEnd : next, next)
                } else if gap > 5.0 {
                    let cap = min(next - 1.5, item.time + max(2.5, min(6.0, Double(item.text.count) * 0.08 + 1.5)))
                    end = item.naturalEnd > item.time ? min(item.naturalEnd, next - 0.1) : cap
                } else {
                    end = item.time
                }
            } else {
                end = item.naturalEnd > item.time ? min(item.naturalEnd, item.time + 10.0) : item.time + 4.0
            }
            return LyricLine(id: i, time: item.time, end: end, text: item.text, charTimings: item.charTimings)
        }

        return (!lines.isEmpty && lines.contains { !$0.charTimings.isEmpty }) ? lines : nil
    }
}
