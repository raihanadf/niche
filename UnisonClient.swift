import Foundation

enum UnisonClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"

    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let clean = LyricsNormalization.cleanTitle(title)
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist

        var comp = URLComponents(string: "https://unison.betterlyrics.org/lyrics")!
        var items = [
            URLQueryItem(name: "song", value: clean),
            URLQueryItem(name: "artist", value: primaryArtist)
        ]
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
        }
        comp.queryItems = items
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool, success,
                  let dObj = json["data"] as? [String: Any],
                  let lyricsStr = dObj["lyrics"] as? String, !lyricsStr.isEmpty else { return nil }

            let format = (dObj["format"] as? String)?.lowercased() ?? "lrc"
            if format == "ttml" {
                return LyricsWordParser.parseTTML(lyricsStr)
            } else if format == "plain" {
                return LyricsParser.parsePlain(lyricsStr)
            } else {
                return LyricsParser.parseLRC(lyricsStr)
            }
        } catch {
            return nil
        }
    }
}
