import Foundation

private func isCJKScalar(_ v: UInt32) -> Bool {
    (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
}

private func hasCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { isCJKScalar($0.value) }
}

private actor DeezerAuthSession {
    static let shared = DeezerAuthSession()
    private var cachedJwt: (token: String, expiresAt: Date)?

    func token() async -> String? {
        if let cached = cachedJwt, cached.expiresAt > Date() {
            return cached.token
        }
        guard let url = URL(string: "https://auth.deezer.com/login/anonymous?jo=p&rto=c") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jwt = json["jwt"] as? String else { return nil }
            cachedJwt = (jwt, Date().addingTimeInterval(300))
            return jwt
        } catch {
            return nil
        }
    }
}

enum DeezerClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist
        guard let trackId = await searchTrack(title: cleanTitle, artist: primaryArtist, duration: duration),
              let jwt = await DeezerAuthSession.shared.token() else {
            return nil
        }

        return await fetchLyrics(trackId: trackId, jwt: jwt)
    }

    private static func searchTrack(title: String, artist: String, duration: Double) async -> Int? {
        let cleanLower = title.lowercased()
        var comp = URLComponents(string: "https://api.deezer.com/search")!
        comp.queryItems = [
            URLQueryItem(name: "q", value: "\(title) \(artist)"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = comp.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["data"] as? [[String: Any]], !tracks.isEmpty else { return nil }
            let matched = tracks.first { track in
                let trackTitle = (track["title"] as? String)?.lowercased() ?? ""
                guard trackTitle.contains(cleanLower) || cleanLower.contains(trackTitle) else { return false }
                if duration > 0, let dur = track["duration"] as? Double {
                    guard abs(dur - duration) <= 3.5 else { return false }
                }
                return true
            }
            return matched?["id"] as? Int
        } catch {
            return nil
        }
    }

    private static func fetchLyrics(trackId: Int, jwt: String) async -> [LyricLine]? {
        guard let url = URL(string: "https://pipe.deezer.com/api") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let query = ["query": "query { track(trackId: \"\(trackId)\") { lyrics { synchronizedLines { milliseconds line } text } } }"]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rootData = json["data"] as? [String: Any],
                  let track = rootData["track"] as? [String: Any],
                  let lyrics = track["lyrics"] as? [String: Any] else { return nil }

            if let syncLines = lyrics["synchronizedLines"] as? [[String: Any]], !syncLines.isEmpty {
                return parseDeezerLines(syncLines)
            }
            if let plain = lyrics["text"] as? String {
                return LyricsParser.parsePlain(plain)
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func parseDeezerLines(_ syncLines: [[String: Any]]) -> [LyricLine] {
        var raw: [(time: Double, text: String)] = []
        for item in syncLines {
            guard let ms = item["milliseconds"] as? Double,
                  let line = item["line"] as? String else { continue }
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { raw.append((ms / 1000.0, text)) }
        }
        return raw.indices.map { i in
            let (time, text) = raw[i]
            let next = i + 1 < raw.count ? raw[i + 1].time : time + 6.0
            let sung = max(2.0, Double(text.split(separator: " ").count) * 0.45 + 1.2)
            let end = max(next - time > sung + 2.0 ? time + sung : next, time + 1.0)
            return LyricLine(id: i, time: time, end: end, text: text, charTimings: LyricsParser.charTimings(text: text, start: time, end: end))
        }
    }
}

enum NetEaseClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist
        let isQueryCJK = hasCJK(title) || hasCJK(artist)

        guard let songId = await searchSong(title: cleanTitle, artist: primaryArtist, duration: duration, isQueryCJK: isQueryCJK) else {
            return nil
        }
        return await fetchLyrics(songId: songId, isQueryCJK: isQueryCJK)
    }

    private static func searchSong(title: String, artist: String, duration: Double, isQueryCJK: Bool) async -> Int? {
        let cleanLower = title.lowercased()
        var comp = URLComponents(string: "https://music.163.com/api/search/get")!
        comp.queryItems = [
            URLQueryItem(name: "s", value: "\(title) \(artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = comp.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]], !songs.isEmpty else { return nil }
            let matched = songs.first { song in
                let songName = (song["name"] as? String)?.lowercased() ?? ""
                if !isQueryCJK && hasCJK(songName) && !songName.contains(cleanLower) {
                    return false
                }
                guard songName.contains(cleanLower) || cleanLower.contains(songName) else { return false }
                if duration > 0, let durMs = song["duration"] as? Double {
                    guard abs(durMs / 1000.0 - duration) <= 3.5 else { return false }
                }
                return true
            }
            return matched?["id"] as? Int
        } catch {
            return nil
        }
    }

    private static func fetchLyrics(songId: Int, isQueryCJK: Bool) async -> [LyricLine]? {
        var comp = URLComponents(string: "https://music.163.com/api/song/lyric")!
        comp.queryItems = [
            URLQueryItem(name: "id", value: "\(songId)"),
            URLQueryItem(name: "lv", value: "1"),
            URLQueryItem(name: "yv", value: "1")
        ]
        guard let url = comp.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = json["lrc"] as? [String: Any],
                  let lyricText = lrc["lyric"] as? String else { return nil }
            let lines = LyricsParser.parseLRC(lyricText)
            guard !lines.isEmpty else { return nil }
            if !isQueryCJK {
                let allChars = lines.map(\.text).joined()
                guard !allChars.isEmpty else { return nil }
                let cjkCount = allChars.unicodeScalars.filter { isCJKScalar($0.value) }.count
                if Double(cjkCount) / Double(allChars.count) > 0.25 {
                    return nil
                }
            }
            return lines
        } catch {
            return nil
        }
    }
}
