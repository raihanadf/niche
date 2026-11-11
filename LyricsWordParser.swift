import Foundation

enum LyricsWordParser {
    typealias RawLine = (time: Double, end: Double, text: String, words: [(start: Double, end: Double, text: String)], agent: String?, isBackground: Bool)

    static func parseTimeSeconds(_ s: String) -> Double? {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("ms") {
            guard let ms = Double(str.dropLast(2)), ms.isFinite, !ms.isNaN, ms >= 0 else { return nil }
            return ms / 1000.0
        }
        if str.hasSuffix("s") { str = String(str.dropLast(1)) }
        if str.contains(":") {
            let parts = str.split(separator: ":", omittingEmptySubsequences: false)
            let p = parts.compactMap { Double($0) }
            guard p.count == parts.count, p.allSatisfy({ $0.isFinite && !$0.isNaN && $0 >= 0 }) else { return nil }
            if p.count == 2 { return p[0] * 60.0 + p[1] }
            if p.count == 3 { return p[0] * 3600.0 + p[1] * 60.0 + p[2] }
            return nil
        }
        guard let v = Double(str), v.isFinite, !v.isNaN, v >= 0 else { return nil }
        return v
    }

    static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    static func isMetadataOrJunkLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let upper = trimmed.uppercased()
        if upper == "EQ" || upper == "♪" || upper == "..." || upper == "•••" { return true }
        if trimmed.allSatisfy({ $0.isWhitespace || "-/.*_".contains($0) }) { return true }
        let lower = trimmed.lowercased()
        let credits = ["作词", "作曲", "编曲", "制作人", "监制", "录音", "混音", "母带", "written by", "lyrics by", "composed by", "produced by", "arranged by", "mastered by", "mixed by"]
        return credits.contains { lower.contains($0) }
    }

    static func isValidDuration(lines: [LyricLine], duration: Double) -> Bool {
        guard duration > 0 else { return !lines.isEmpty }
        guard !lines.isEmpty else { return false }
        if duration > 30.0, lines.count < 2 { return false }
        let lastEnd = lines.map(\.end).max()!
        guard lastEnd > 0 else { return false }
        if lastEnd > duration + 6.0 { return false }
        return lastEnd >= (duration * 0.70) || abs(lastEnd - duration) <= 8.0
    }

    static func wordTimingsToCharTimings(
        fullText: String, words: [(start: Double, end: Double, text: String)], lineStart: Double
    ) -> [Double] {
        guard !fullText.isEmpty, !words.isEmpty else { return [] }
        let chars = Array(fullText), totalCount = chars.count
        var timings = [Double](repeating: lineStart, count: totalCount)
        var cursor = 0, prevEnd = lineStart
        for w in words {
            let dur = max(0.01, w.end - w.start)
            let cleanWord = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanWord.isEmpty else { prevEnd = max(prevEnd, w.end); continue }
            let target = Array(cleanWord), tLen = target.count
            let matchIdx = cursor + tLen <= totalCount
                ? (cursor...(totalCount - tLen)).first { chars[$0..<($0 + tLen)].elementsEqual(target) }
                : nil
            if let match = matchIdx {
                if match > cursor { for i in cursor..<match { timings[i] = prevEnd } }
                let step = dur / Double(max(1, tLen))
                for i in 0..<tLen { timings[match + i] = w.start + Double(i) * step }
                cursor = match + tLen; prevEnd = w.end
            } else {
                prevEnd = max(prevEnd, w.end)
            }
        }
        if cursor < totalCount { for i in cursor..<totalCount { timings[i] = prevEnd } }
        var curr = lineStart
        for i in 0..<totalCount {
            if timings[i] < curr { timings[i] = curr } else { curr = timings[i] }
        }
        return timings
    }

    private static func buildLines(_ raw: [RawLine], expectedDuration: Double?) -> [LyricLine]? {
        guard !raw.isEmpty else { return nil }
        let sorted = raw.sorted { ($0.time, $0.isBackground ? 1 : 0) < ($1.time, $1.isBackground ? 1 : 0) }
        let lines = sorted.indices.map { idx in
            let item = sorted[idx]
            let timings = wordTimingsToCharTimings(fullText: item.text, words: item.words, lineStart: item.time)
            return LyricLine(id: idx, time: item.time, end: max(item.time, item.end), text: item.text,
                             charTimings: timings, agent: item.agent, isBackground: item.isBackground)
        }
        if let exp = expectedDuration, exp > 0, !isValidDuration(lines: lines, duration: exp) { return nil }
        return lines.isEmpty ? nil : lines
    }

    static func extractBackgroundSpans(_ body: String) -> (mainBody: String, bgBodies: [(attrs: String, body: String)]) {
        let bgRole = #/\b(?:ttm:)?role="x-bg"/#
        var mainBody = "", bgBodies: [(attrs: String, body: String)] = [], cursor = body.startIndex

        while cursor < body.endIndex {
            guard let open = body[cursor...].firstMatch(of: #/<span(?=[\s>/])([^>]*)>/#) else {
                mainBody += body[cursor...]
                break
            }
            let rawAttrs = String(open.1)
            let selfClosing = rawAttrs.trimmingCharacters(in: .whitespaces).hasSuffix("/")
            let isBg = rawAttrs.contains(bgRole)
            if selfClosing || !isBg {
                mainBody += (selfClosing && isBg) ? body[cursor..<open.range.lowerBound] : body[cursor..<open.range.upperBound]
                cursor = open.range.upperBound
                continue
            }
            mainBody += body[cursor..<open.range.lowerBound]
            let contentStart = open.range.upperBound
            var scan = contentStart, depth = 1
            while depth > 0, scan < body.endIndex {
                guard let tok = body[scan...].firstMatch(of: #/<span(?=[\s>/])|<\/span\s*>/#) else { depth = -1; break }
                if body[tok.range].hasPrefix("</") {
                    depth -= 1
                    if depth == 0 {
                        bgBodies.append((attrs: rawAttrs, body: String(body[contentStart..<tok.range.lowerBound])))
                        cursor = tok.range.upperBound
                    } else { scan = tok.range.upperBound }
                } else {
                    guard let gt = body[tok.range.upperBound...].firstIndex(of: ">") else { depth = -1; break }
                    if !body[tok.range.upperBound..<gt].trimmingCharacters(in: .whitespaces).hasSuffix("/") { depth += 1 }
                    scan = body.index(after: gt)
                }
            }
            if depth != 0 { cursor = body.endIndex; break }
        }
        return (mainBody, bgBodies)
    }

    private static func parseBeginEnd(_ attrs: String) -> (begin: Double?, end: Double?) {
        var begin: Double?, end: Double?
        for attr in attrs.matches(of: #/\b(begin|end)="([^"]+)"/#) {
            if attr.1 == "begin" { begin = parseTimeSeconds(String(attr.2)) }
            else { end = parseTimeSeconds(String(attr.2)) }
        }
        return (begin, end)
    }

    private static func parseLeafWords(_ body: String, fallbackBegin: Double, fallbackEnd: Double) -> [(start: Double, end: Double, text: String)] {
        body.matches(of: #/<span\b([^>]*)>([^<]+)</span\s*>/#.dotMatchesNewlines()).map { s in
            let (b, e) = parseBeginEnd(String(s.1))
            let start = b ?? fallbackBegin
            let sText = unescapeXML(String(s.2)).replacing(#/\s+/#, with: " ")
            return (start: start, end: max(start, e ?? fallbackEnd), text: sText)
        }
    }

    private static func cleanTTMLText(_ body: String) -> String {
        unescapeXML(body.replacing(#/<[^>]+>/#, with: "")).replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTTML(_ xml: String, expectedDuration: Double? = nil) -> [LyricLine]? {
        if let exp = expectedDuration, exp > 0,
           let durMatch = xml.firstMatch(of: #/<body\b[^>]*\bdur="([^"]+)"/#),
           let bodySec = parseTimeSeconds(String(durMatch.1)), abs(bodySec - exp) > 4.0 { return nil }
        let pMatches = xml.matches(of: #/<p\b([^>]*)>(.*?)</p>/#.dotMatchesNewlines())
        guard !pMatches.isEmpty else { return nil }
        let bgRole = #/\b(?:ttm:)?role="x-bg"/#
        var rawLines: [RawLine] = []

        for pMatch in pMatches {
            let pAttrs = String(pMatch.1), pBody = String(pMatch.2)
            let (pBegin, pEnd) = parseBeginEnd(pAttrs)
            guard let start = pBegin else { continue }
            let pAgent = pAttrs.firstMatch(of: #/\bttm:agent="([^"]+)"/#).map { String($0.1) }
            let pIsBg = pAttrs.contains(bgRole)
            let (mainBody, bgBodies) = extractBackgroundSpans(pBody)

            let mainWords = parseLeafWords(mainBody, fallbackBegin: start, fallbackEnd: max(start, pEnd ?? (start + 2.0)))
            let mainText = cleanTTMLText(mainBody)
            if !mainText.isEmpty, !isMetadataOrJunkLine(mainText) {
                let time = mainWords.first?.start ?? start
                let end = max(time, mainWords.last?.end ?? pEnd ?? (time + 3.0))
                rawLines.append((time: time, end: end, text: mainText, words: mainWords, agent: pAgent, isBackground: pIsBg))
            }
            for (bgAttrs, bgBody) in bgBodies {
                let (bgSpanBegin, bgSpanEnd) = parseBeginEnd(bgAttrs)
                let bgText = cleanTTMLText(bgBody)
                guard !bgText.isEmpty, !isMetadataOrJunkLine(bgText) else { continue }
                let bgAgent = bgAttrs.firstMatch(of: #/\bttm:agent="([^"]+)"/#).map { String($0.1) } ?? pAgent
                let fbBegin = bgSpanBegin ?? start, fbEnd = max(fbBegin, bgSpanEnd ?? pEnd ?? (fbBegin + 2.0))
                let bgWords = parseLeafWords(bgBody, fallbackBegin: fbBegin, fallbackEnd: fbEnd)
                let bgTime = bgWords.first?.start ?? bgSpanBegin ?? start
                let bgEnd = max(bgTime, bgWords.last?.end ?? bgSpanEnd ?? pEnd ?? (bgTime + 2.0))
                rawLines.append((time: bgTime, end: bgEnd, text: bgText, words: bgWords, agent: bgAgent, isBackground: true))
            }
        }
        return buildLines(rawLines, expectedDuration: expectedDuration)
    }

    static func parseKPOE(_ data: Data, expectedDuration: Double? = nil) -> [LyricLine]? {
        struct KpoeResponse: Decodable {
            struct Metadata: Decodable { let totalDuration: String? }
            struct LyricItem: Decodable {
                struct Element: Decodable { let singer: String? }
                struct Syllable: Decodable { let time: Int, duration: Int, text: String, isBackground: Bool? }
                let time: Int, duration: Int, text: String, element: Element?, isBackground: Bool?, syllabus: [Syllable]?
            }
            let metadata: Metadata?, lyrics: [LyricItem]?
        }
        guard let resp = try? JSONDecoder().decode(KpoeResponse.self, from: data),
              let lyricItems = resp.lyrics, !lyricItems.isEmpty else { return nil }
        if let exp = expectedDuration, exp > 0,
           let durStr = resp.metadata?.totalDuration,
           let totalSec = parseTimeSeconds(durStr), abs(totalSec - exp) > 4.0 { return nil }

        let toWords: ([KpoeResponse.LyricItem.Syllable]) -> [(start: Double, end: Double, text: String)] = { syls in
            syls.compactMap { s in
                guard s.time >= 0, s.duration >= 0 else { return nil }
                return (start: Double(s.time) / 1000.0, end: Double(s.time + s.duration) / 1000.0, text: s.text)
            }
        }
        var rawLines: [RawLine] = []
        for item in lyricItems where item.time >= 0 && item.duration >= 0 {
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty, !isMetadataOrJunkLine(trimmedText) else { continue }
            let start = Double(item.time) / 1000.0, end = Double(item.time + item.duration) / 1000.0
            let agent = item.element?.singer.flatMap { $0.isEmpty ? nil : $0 }
            let syls = item.syllabus ?? [], mainSyls = syls.filter { $0.isBackground != true }, bgSyls = syls.filter { $0.isBackground == true }
            if !mainSyls.isEmpty, !bgSyls.isEmpty {
                let mainWords = toWords(mainSyls), bgWords = toWords(bgSyls)
                let mainText = mainSyls.map(\.text).joined().replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let bgText = bgSyls.map(\.text).joined().replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !mainText.isEmpty, !isMetadataOrJunkLine(mainText) {
                    rawLines.append((time: mainWords.first?.start ?? start, end: mainWords.last?.end ?? end,
                                     text: mainText, words: mainWords, agent: agent, isBackground: false))
                }
                if !bgText.isEmpty, !isMetadataOrJunkLine(bgText) {
                    rawLines.append((time: bgWords.first?.start ?? start, end: bgWords.last?.end ?? end,
                                     text: bgText, words: bgWords, agent: agent, isBackground: true))
                }
            } else {
                let isBg = item.isBackground ?? (!bgSyls.isEmpty && mainSyls.isEmpty)
                rawLines.append((time: start, end: end, text: trimmedText, words: toWords(syls), agent: agent, isBackground: isBg))
            }
        }
        return buildLines(rawLines, expectedDuration: expectedDuration)
    }
}
