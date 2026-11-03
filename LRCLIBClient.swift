import Foundation

enum LRCLIBClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (https://github.com/raihanadf/niche)"

    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        let artists = LyricsNormalization.artistVariants(artist)
        let primaryArtist = artists.first ?? artist

        var cascades: [[String: String]] = [
            ["track_name": cleanTitle, "artist_name": primaryArtist],
            ["q": "\(primaryArtist) \(cleanTitle)"]
        ]
        if artists.count > 1 {
            for a in artists.dropFirst() {
                cascades.append(["track_name": cleanTitle, "artist_name": a])
            }
        }
        cascades.append(["track_name": cleanTitle])

        for query in cascades {
            guard let items = await search(query), !items.isEmpty else { continue }
            let scored = items.compactMap { item -> ([LyricLine], Int)? in
                guard let lines = parse(item),
                      let score = score(item, cleanTitle: cleanTitle, artists: artists, duration: duration) else {
                    return nil
                }
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
            return nil
        }
    }

    private static func score(_ item: [String: Any], cleanTitle: String, artists: [String], duration: Double) -> Int? {
        let hasSynced = (item["syncedLyrics"] as? String)?.isEmpty == false
        var score = hasSynced ? 1000 : 400

        let itemTitle = (item["trackName"] as? String)?.lowercased() ?? ""
        let cleanLower = cleanTitle.lowercased()
        if itemTitle == cleanLower {
            score += 500
        } else if itemTitle.contains(cleanLower) || cleanLower.contains(itemTitle) {
            score += 250
        }

        let itemArtist = (item["artistName"] as? String)?.lowercased() ?? ""
        var artistMatched = false
        for a in artists {
            let aLower = a.lowercased()
            if itemArtist == aLower {
                score += 400
                artistMatched = true
                break
            } else if itemArtist.contains(aLower) || aLower.contains(itemArtist) {
                score += 200
                artistMatched = true
                break
            }
        }

        if duration > 0, let itemDur = item["duration"] as? Double {
            let diff = abs(itemDur - duration)
            if diff <= 3.0 {
                score += 300
            } else if diff <= 8.0 {
                score += 150
            } else if diff <= 15.0 {
                score += 50
            } else if diff > 30.0 {
                if !artistMatched || (itemTitle != cleanLower && !itemTitle.contains(cleanLower)) {
                    return nil
                }
                score -= 200
            }
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
