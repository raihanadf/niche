import Foundation

enum LRCLIBClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String) (https://github.com/raihanadf/niche)"

    static func fetch(title: String, artist: String, album: String? = nil, duration: Double) async -> [LyricLine]? {
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        let artists = LyricsNormalization.artistVariants(artist)
        let primaryArtist = artists.first ?? artist
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAlbum = (trimmedAlbum?.isEmpty == false) ? trimmedAlbum : nil

        var cascades: [[String: String]] = []
        if let effectiveAlbum {
            cascades.append(["track_name": cleanTitle, "artist_name": primaryArtist, "album_name": effectiveAlbum])
        }
        cascades.append(["track_name": cleanTitle, "artist_name": primaryArtist])
        cascades.append(["q": "\(primaryArtist) \(cleanTitle)"])
        if artists.count > 1 {
            for a in artists.dropFirst() {
                if let effectiveAlbum {
                    cascades.append(["track_name": cleanTitle, "artist_name": a, "album_name": effectiveAlbum])
                }
                cascades.append(["track_name": cleanTitle, "artist_name": a])
            }
        }
        cascades.append(["track_name": cleanTitle])

        for query in cascades {
            guard let items = await search(query), !items.isEmpty else { continue }
            let scored = items.compactMap { item -> ([LyricLine], Int)? in
                guard let lines = parse(item),
                      let score = score(item, cleanTitle: cleanTitle, artists: artists, album: effectiveAlbum, duration: duration) else {
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
            NSLog("Niche could not reach lrclib: %@", String(describing: error))
            return nil
        }
    }

    private static func score(_ item: [String: Any], cleanTitle: String, artists: [String], album: String?, duration: Double) -> Int? {
        let hasSynced = (item["syncedLyrics"] as? String)?.isEmpty == false
        var score = hasSynced ? 1000 : 400

        let itemTitle = (item["trackName"] as? String)?.lowercased() ?? ""
        let cleanLower = cleanTitle.lowercased()
        if itemTitle == cleanLower {
            score += 500
        } else if itemTitle.contains(cleanLower) || cleanLower.contains(itemTitle) {
            score += 250
        }
        if let have = (item["artistName"] as? String)?.lowercased(), !have.isEmpty,
           let want = artists.lazy.map({ $0.lowercased() }).first(where: { have.contains($0) || $0.contains(have) }) {
            score += have == want ? 400 : 200
        }

        if let album = album?.lowercased(), !album.isEmpty {
            let itemAlbum = (item["albumName"] as? String)?.lowercased() ?? ""
            if itemAlbum == album {
                score += 200
            } else if itemAlbum.contains(album) || album.contains(itemAlbum) {
                score += 100
            }
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
