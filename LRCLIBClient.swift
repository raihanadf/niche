import Foundation

enum LRCLIBClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String) (https://github.com/raihanadf/niche)"

    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let song = LyricsNormalization.song(title: title, artist: artist)
        var queries = song.artists.map { ["track_name": song.title, "artist_name": $0] }
        queries.insert(["q": (song.artists.prefix(1) + [song.title]).joined(separator: " ")], at: min(1, queries.count))
        queries.append(["track_name": song.title])

        for query in queries {
            guard let items = await search(query), !items.isEmpty else { continue }
            let scored = items.compactMap { item -> ([LyricLine], Int)? in
                guard let lines = parse(item), let score = score(item, title: song.title, artists: song.artists, duration: duration) else { return nil }
                return (lines, score)
            }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 400 {
                return best.0
            }
        }
        return nil
    }

    private static func search(_ params: [String: String]) async -> [[String: Any]]? {
        var comp = URLComponents(string: "https://lrclib.net/api/search")!
        comp.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comp.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            NSLog("Niche could not reach lrclib: %@", String(describing: error))
            return nil
        }
    }

    private static func score(_ item: [String: Any], title: String, artists: [String], duration: Double) -> Int? {
        var score = (item["syncedLyrics"] as? String)?.isEmpty == false ? 1000 : 400
        let wantTitle = title.lowercased()
        if let have = (item["trackName"] as? String)?.lowercased(), !have.isEmpty, !wantTitle.isEmpty {
            score += have == wantTitle ? 500 : have.contains(wantTitle) || wantTitle.contains(have) ? 250 : 0
        }
        if let have = (item["artistName"] as? String)?.lowercased(), !have.isEmpty,
           let want = artists.lazy.map({ $0.lowercased() }).first(where: { have.contains($0) || $0.contains(have) }) {
            score += have == want ? 400 : 200
        }

        if duration > 0, let itemDur = item["duration"] as? Double {
            let diff = abs(itemDur - duration)
            guard diff <= 2.5 else { return nil }
            score += 300
        }
        return score
    }

    private static func parse(_ item: [String: Any]) -> [LyricLine]? {
        if let synced = item["syncedLyrics"] as? String {
            let lines = LyricsParser.parseLRC(synced)
            if !lines.isEmpty { return lines }
        }
        if let plain = item["plainLyrics"] as? String {
            let lines = LyricsParser.parsePlain(plain)
            if !lines.isEmpty { return lines }
        }
        return nil
    }
}
