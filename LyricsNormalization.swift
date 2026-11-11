import Foundation

enum LyricsNormalization {
    private static let bracketsRegex = try! NSRegularExpression(
        pattern: #"\s*(\([^)]*\)|\[[^\]]*\]|【[^】]*】|（[^）]*）)"#
    )

    private static let trailingPunctuation = CharacterSet(charactersIn: " \"“”.,-~")

    static func searchTitle(_ title: String) -> String {
        var cleaned = title
        if let pipe = cleaned.firstIndex(of: "|") {
            cleaned = String(cleaned[..<pipe])
        }
        let unbracketed = replace(bracketsRegex, in: cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return unbracketed.isEmpty ? cleaned.trimmingCharacters(in: .whitespacesAndNewlines) : unbracketed
    }

    static func cleanTitle(_ title: String) -> String {
        var cleaned = searchTitle(title)
        if let dashRange = cleaned.range(of: " - ", options: .backwards) {
            let suffix = cleaned[dashRange.upperBound...].lowercased()
            if ["official", "video", "audio", "lyrics", "lyric", "visualizer", "mv"].contains(where: { suffix.contains($0) }) {
                cleaned = String(cleaned[..<dashRange.lowerBound])
            }
        }
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        var result = cleaned.trimmingCharacters(in: trailingPunctuation)
        if result.hasPrefix("'") && result.hasSuffix("'") && result.count > 1 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: trailingPunctuation)
        }
        return result.isEmpty ? title.trimmingCharacters(in: trailingPunctuation) : result
    }

    private static func artistVariants(_ artist: String) -> [String] {
        var list: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: trailingPunctuation)
            guard !t.isEmpty, !list.contains(t) else { return }
            list.append(t)
        }

        if artist.hasPrefix(".") { add(String(artist.dropFirst())) }
        add(artist)
        let separators = #/\s*(?:,|&|\band\b|\bx\b|\bfeat\.?\b|\bft\.?\b|\bwith\b)\s*/#.ignoresCase()
        let parts = artist.split(separator: separators).map(String.init)
        if parts.count > 1 {
            for part in parts {
                if part.hasPrefix(".") { add(String(part.dropFirst())) }
                add(part)
            }
        }
        return list
    }

    static func isCJKScalar(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
    }

    static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJKScalar($0.value) }
    }

    static func hasEastAsianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            let v = $0.value
            return isCJKScalar(v) || (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v)
        }
    }

    static func cjkRatio(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        let cjkCount = scalars.reduce(0) { $0 + (isCJKScalar($1.value) ? 1 : 0) }
        return Double(cjkCount) / Double(scalars.count)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
