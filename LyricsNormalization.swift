import Foundation

enum LyricsNormalization {
    private static let noiseRegex = try! NSRegularExpression(
        pattern: #"\s*[(\[](official( music| lyric)? video|official audio|audio|lyrics?( video)?|visuali[sz]er|mv|4k|hd|live[^)\]]*|f(ea)?t\.[^)\]]*|prod\.[^)\]]*|video musik resmi|video lirik)[)\]]"#,
        options: .caseInsensitive
    )

    private static let versionRegex = try! NSRegularExpression(
        pattern: #"\s*[(\[][^)\]]*(remix|edit|version|live|acoustic|sped up|slowed|remastered)[^)\]]*[)\]]"#,
        options: .caseInsensitive
    )

    private static let trailingPunctuation = CharacterSet(charactersIn: " \"'“”.,-~")

    static func cleanTitle(_ title: String) -> String {
        var cleaned = replace(noiseRegex, in: title)
        cleaned = replace(versionRegex, in: cleaned)
        if let dashRange = cleaned.range(of: " - ", options: .backwards) {
            let suffix = cleaned[dashRange.upperBound...].lowercased()
            if ["official", "video", "audio", "lyrics", "lyric", "visualizer", "mv"].contains(where: { suffix.contains($0) }) {
                cleaned = String(cleaned[..<dashRange.lowerBound])
            }
        }
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: ".")
        }
        return cleaned.trimmingCharacters(in: trailingPunctuation)
    }

    static func artistVariants(_ artist: String) -> [String] {
        var raw = artist.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Topic", "VEVO"] where raw.hasSuffix(suffix) {
            raw = String(raw.dropLast(suffix.count))
        }
        raw = raw.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return [] }

        var list: [String] = []

        func add(_ s: String) {
            let t = s.trimmingCharacters(in: trailingPunctuation)
            guard !t.isEmpty, !list.contains(t) else { return }
            list.append(t)
        }

        if raw.hasPrefix(".") {
            add(String(raw.dropFirst()))
        }
        add(raw)

        let separators = #/\s*(?:,|&|\band\b|\bx\b|\bfeat\.?\b|\bft\.?\b|\bwith\b)\s*/#.ignoresCase()
        let parts = raw.split(separator: separators).map(String.init)
        if parts.count > 1 {
            for part in parts {
                if part.hasPrefix(".") { add(String(part.dropFirst())) }
                add(part)
            }
        }
        return list
    }

    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
