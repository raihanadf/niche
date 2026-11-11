import Foundation

private func artistsMatch(_ rawNames: [String], against targetVariants: [String]) -> Bool {
    let targets = targetVariants.map { $0.lowercased() }.filter { !$0.isEmpty }
    let candidates = rawNames.flatMap { LyricsNormalization.artistVariants($0) }.map { $0.lowercased() }.filter { !$0.isEmpty }
    return targets.contains { t in
        candidates.contains { c in c == t || (min(c.count, t.count) >= 3 && (c.contains(t) || t.contains(c))) }
    }
}

private func fetchJSON(_ url: URL, cookies: Bool = true, configure: ((inout URLRequest) throws -> Void)? = nil) async -> [String: Any]? {
    var req = URLRequest(url: url, timeoutInterval: 4)
    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    req.httpShouldHandleCookies = cookies
    do {
        try configure?(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard !Task.isCancelled, (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    } catch {
        NSLog("Niche could not reach %@: %@", url.absoluteString, String(describing: error))
        return nil
    }
}

private actor DeezerAuthSession {
    static let shared = DeezerAuthSession()
    private var cachedJwt: (token: String, expiresAt: Date)?

    func token() async -> String? {
        guard !Task.isCancelled else { return nil }
        if let cached = cachedJwt, cached.expiresAt > Date() { return cached.token }
        guard let url = URL(string: "https://auth.deezer.com/login/anonymous?jo=p&rto=c"),
              let json = await fetchJSON(url),
              let jwt = json["jwt"] as? String else { return nil }
        cachedJwt = (jwt, Date().addingTimeInterval(300))
        return jwt
    }
}

enum DeezerClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        guard !Task.isCancelled else { return nil }
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        guard let trackId = await searchTrack(title: cleanTitle, artist: artist, duration: duration),
              !Task.isCancelled,
              let jwt = await DeezerAuthSession.shared.token(),
              !Task.isCancelled else {
            return nil
        }
        return await fetchLyrics(trackId: trackId, jwt: jwt)
    }

    private static func searchTrack(title: String, artist: String, duration: Double) async -> Int? {
        let cleanLower = title.lowercased()
        let artistVariants = LyricsNormalization.artistVariants(artist)
        let primaryArtist = artistVariants.first ?? artist
        let query = [title, primaryArtist].filter { !$0.isEmpty }.joined(separator: " ")
        var comp = URLComponents(string: "https://api.deezer.com/search")!
        comp.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "5")]
        guard let url = comp.url,
              let json = await fetchJSON(url),
              let tracks = json["data"] as? [[String: Any]], !tracks.isEmpty else { return nil }
        let matched = tracks.first { track in
            guard !(track["id"] is Bool), track["id"] is Int else { return false }
            let trackTitle = (track["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard !trackTitle.isEmpty, !cleanLower.isEmpty,
                  trackTitle.count >= min(3, cleanLower.count),
                  trackTitle.contains(cleanLower) || cleanLower.contains(trackTitle) else { return false }
            if duration > 0 {
                guard !(track["duration"] is Bool),
                      let dur = track["duration"] as? Double,
                      dur.isFinite, dur > 0, abs(dur - duration) <= 3.5 else { return false }
            }
            if !artistVariants.isEmpty {
                guard let artistName = (track["artist"] as? [String: Any])?["name"] as? String,
                      artistsMatch([artistName], against: artistVariants) else { return false }
            }
            return true
        }
        return matched?["id"] as? Int
    }

    private static func fetchLyrics(trackId: Int, jwt: String) async -> [LyricLine]? {
        guard let url = URL(string: "https://pipe.deezer.com/api") else { return nil }
        let query = ["query": "query { track(trackId: \"\(trackId)\") { lyrics { synchronizedLines { milliseconds line } text } } }"]
        guard let json = await fetchJSON(url, configure: { req in
            req.httpMethod = "POST"
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
        }),
              let rootData = json["data"] as? [String: Any],
              let track = rootData["track"] as? [String: Any],
              let lyrics = track["lyrics"] as? [String: Any] else { return nil }
        if let syncLines = lyrics["synchronizedLines"] as? [[String: Any]], !syncLines.isEmpty {
            let parsed = parseDeezerLines(syncLines)
            if !parsed.isEmpty { return parsed }
        }
        if let plain = lyrics["text"] as? String {
            let parsed = LyricsParser.parsePlain(plain)
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    private static func parseDeezerLines(_ syncLines: [[String: Any]]) -> [LyricLine] {
        var raw: [(time: Double, text: String)] = []
        for item in syncLines {
            guard !(item["milliseconds"] is Bool),
                  let ms = item["milliseconds"] as? Double,
                  ms.isFinite, ms >= 0, ms < 86_400_000,
                  let line = item["line"] as? String else { continue }
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !LyricsWordParser.isMetadataOrJunkLine(text) {
                raw.append((ms / 1000.0, text))
            }
        }
        let sorted = raw.sorted { $0.time < $1.time }
        return sorted.indices.map { i in
            let (time, text) = sorted[i]
            let next = i + 1 < sorted.count ? sorted[i + 1].time : time + 6.0
            let sung = max(2.0, Double(text.split(separator: " ").count) * 0.45 + 1.2)
            var end = max(next - time > sung + 2.0 ? time + sung : next, time + 1.0)
            if i + 1 < sorted.count, next > time { end = min(end, next) }
            return LyricLine(id: i, time: time, end: end, text: text, charTimings: [])
        }
    }
}

enum NetEaseClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        guard !Task.isCancelled else { return nil }
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        let isQueryEastAsian = LyricsNormalization.hasEastAsianScript(title) || LyricsNormalization.hasEastAsianScript(artist)

        let songIds = await searchSong(title: cleanTitle, artist: artist, duration: duration, isQueryEastAsian: isQueryEastAsian)
        for songId in songIds {
            guard !Task.isCancelled else { return nil }
            if let lines = await fetchLyrics(songId: songId, duration: duration, isQueryEastAsian: isQueryEastAsian) {
                return lines
            }
        }
        return nil
    }

    private static func searchSong(title: String, artist: String, duration: Double, isQueryEastAsian: Bool) async -> [Int] {
        let cleanLower = title.lowercased()
        let artistVariants = LyricsNormalization.artistVariants(artist)
        let primaryArtist = artistVariants.first ?? artist
        let query = [title, primaryArtist].filter { !$0.isEmpty }.joined(separator: " ")
        var comp = URLComponents(string: "https://music.163.com/api/search/get")!
        comp.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = comp.url,
              let json = await fetchJSON(url, cookies: false),
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]], !songs.isEmpty else { return [] }
        var ranked: [(id: Int, artistMatch: Bool, diff: Double, idx: Int)] = []
        for (idx, song) in songs.enumerated() {
            guard !(song["id"] is Bool), let id = song["id"] as? Int else { continue }
            let songName = (song["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !isQueryEastAsian && LyricsNormalization.hasCJK(songName) && !songName.contains(cleanLower) { continue }
            guard !songName.isEmpty, !cleanLower.isEmpty,
                  songName.count >= min(3, cleanLower.count),
                  songName.contains(cleanLower) || cleanLower.contains(songName) else { continue }
            var diff = 0.0
            if duration > 0 {
                guard !(song["duration"] is Bool),
                      let durMs = song["duration"] as? Double,
                      durMs.isFinite, durMs > 0 else { continue }
                diff = abs(durMs / 1000.0 - duration)
                guard diff <= 3.5 else { continue }
            }
            var artistMatch = false
            if !artistVariants.isEmpty, let artistsArr = song["artists"] as? [[String: Any]] {
                let names = artistsArr.compactMap { $0["name"] as? String }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !names.isEmpty {
                    guard artistsMatch(names, against: artistVariants) else { continue }
                    artistMatch = true
                }
            }
            ranked.append((id: id, artistMatch: artistMatch, diff: diff, idx: idx))
        }
        ranked.sort {
            if $0.artistMatch != $1.artistMatch { return $0.artistMatch }
            if duration > 0, $0.diff != $1.diff { return $0.diff < $1.diff }
            return $0.idx < $1.idx
        }
        return Array(ranked.prefix(3).map(\.id))
    }

    private static func fetchLyrics(songId: Int, duration: Double, isQueryEastAsian: Bool) async -> [LyricLine]? {
        var comp = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comp.queryItems = [
            URLQueryItem(name: "id", value: "\(songId)"),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "yv", value: "1")
        ]
        guard let url = comp.url,
              let json = await fetchJSON(url, cookies: false) else { return nil }
        if let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String,
           let yrcLines = YRCParser.parse(yrc),
           passesCJKCheck(yrcLines, isQueryEastAsian: isQueryEastAsian),
           LyricsWordParser.isValidDuration(lines: yrcLines, duration: duration) {
            return yrcLines
        }
        guard let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String else { return nil }
        let lrcLines = LyricsParser.parseLRC(lrc)
        guard !lrcLines.isEmpty,
              passesCJKCheck(lrcLines, isQueryEastAsian: isQueryEastAsian),
              LyricsWordParser.isValidDuration(lines: lrcLines, duration: duration) else { return nil }
        return lrcLines
    }

    private static func passesCJKCheck(_ lines: [LyricLine], isQueryEastAsian: Bool) -> Bool {
        guard !lines.isEmpty else { return false }
        guard !isQueryEastAsian else { return true }
        let allChars = lines.map(\.text).joined()
        guard !allChars.isEmpty else { return false }
        return LyricsNormalization.cjkRatio(allChars) <= 0.25
    }
}
