import Foundation

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
            NSLog("Niche could not reach deezer: %@", String(describing: error))
            return nil
        }
    }
}

enum DeezerClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let song = LyricsNormalization.song(title: title, artist: artist)
        let query = ([song.title] + song.artists.prefix(1)).joined(separator: " ")

        guard let trackId = await searchTrack(query: query, duration: duration),
              let jwt = await DeezerAuthSession.shared.token() else {
            return nil
        }

        return await fetchLyrics(trackId: trackId, jwt: jwt)
    }

    private static func searchTrack(query: String, duration: Double) async -> Int? {
        var comp = URLComponents(string: "https://api.deezer.com/search")!
        comp.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "5")]
        guard let url = comp.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tracks = json["data"] as? [[String: Any]], !tracks.isEmpty else { return nil }
            let matched = tracks.first { track in
                guard duration > 0, let dur = track["duration"] as? Double else { return true }
                return abs(dur - duration) <= 12.0
            }
            return matched?["id"] as? Int
        } catch {
            NSLog("Niche could not reach deezer: %@", String(describing: error))
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
            NSLog("Niche could not reach deezer: %@", String(describing: error))
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
        let song = LyricsNormalization.song(title: title, artist: artist)
        let query = ([song.title] + song.artists.prefix(1)).joined(separator: " ")

        guard let songId = await searchSong(query: query, duration: duration) else { return nil }
        return await fetchLyrics(songId: songId)
    }

    private static func searchSong(query: String, duration: Double) async -> Int? {
        var comp = URLComponents(string: "https://music.163.com/api/search/get")!
        comp.queryItems = [
            URLQueryItem(name: "s", value: query),
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
                guard duration > 0, let durMs = song["duration"] as? Double else { return true }
                return abs(durMs / 1000.0 - duration) <= 12.0
            }
            return matched?["id"] as? Int
        } catch {
            NSLog("Niche could not reach netease: %@", String(describing: error))
            return nil
        }
    }

    private static func fetchLyrics(songId: Int) async -> [LyricLine]? {
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
            return lines.isEmpty ? nil : lines
        } catch {
            NSLog("Niche could not reach netease: %@", String(describing: error))
            return nil
        }
    }
}
