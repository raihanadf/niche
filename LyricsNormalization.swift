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

    static func song(title: String, artist: String) -> (title: String, artists: [String]) {
        var artist = artist.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Topic", "VEVO"] where artist.hasSuffix(suffix) { artist = String(artist.dropLast(suffix.count)) }
        artist = artist.trimmingCharacters(in: .whitespaces)
        var title = cleanTitle(title)
        let parts = title.components(separatedBy: " - ")
        let isChannel = ["kexp", "vevo", "records", "channel", "music", "tv"].contains { artist.lowercased().contains($0) }
        if parts.count > 1, artist.isEmpty || isChannel || artist.caseInsensitiveCompare(parts[0]) == .orderedSame {
            artist = parts[0]
            title = parts.dropFirst().joined(separator: " - ")
        }
        return (title.trimmingCharacters(in: trailingPunctuation), artistVariants(artist))
    }

    private static func cleanTitle(_ title: String) -> String {
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

    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
