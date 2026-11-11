import Foundation

enum QQMusicClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let isQueryCJK = LyricsNormalization.hasCJK(title) || LyricsNormalization.hasCJK(artist)
        let query = "\(title) \(artist)"
        var comp = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        comp.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "key", value: query)
        ]
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songData = (json["data"] as? [String: Any])?["song"] as? [String: Any],
                  let items = songData["itemlist"] as? [[String: Any]] else { return nil }

            let mids = items.compactMap { $0["mid"] as? String }
            guard !mids.isEmpty else { return nil }

            var dComp = URLComponents(string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg")!
            dComp.queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "songmid", value: mids.joined(separator: ","))
            ]
            guard let detailUrl = dComp.url else { return nil }
            var detailReq = URLRequest(url: detailUrl, timeoutInterval: 4)
            detailReq.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")
            detailReq.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

            let (dData, _) = try await URLSession.shared.data(for: detailReq)
            guard let dJson = try JSONSerialization.jsonObject(with: dData) as? [String: Any],
                  let dSongs = dJson["data"] as? [[String: Any]] else { return nil }

            let targetMid: String? = {
                if duration > 0 {
                    return dSongs.first { s in
                        guard let interval = s["interval"] as? Double else { return false }
                        return abs(interval - duration) <= 3.5
                    }?["mid"] as? String
                }
                return dSongs.first?["mid"] as? String
            }()

            guard let mid = targetMid else { return nil }
            var lComp = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
            lComp.queryItems = [
                URLQueryItem(name: "songmid", value: mid),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "nobase64", value: "1")
            ]
            guard let lyricUrl = lComp.url else { return nil }

            var lyricReq = URLRequest(url: lyricUrl, timeoutInterval: 4)
            lyricReq.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")
            lyricReq.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")

            let (lData, _) = try await URLSession.shared.data(for: lyricReq)
            guard let lJson = try JSONSerialization.jsonObject(with: lData) as? [String: Any] else { return nil }

            var lyricRaw = lJson["lyric"] as? String ?? ""
            if lyricRaw.count < 1_000_000, !lyricRaw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
               let b64Data = Data(base64Encoded: lyricRaw, options: .ignoreUnknownCharacters),
               let decoded = String(data: b64Data, encoding: .utf8) {
                lyricRaw = decoded
            }

            if !isQueryCJK && LyricsNormalization.cjkRatio(lyricRaw) > 0.25 { return nil }
            let lines = LyricsParser.parseLRC(lyricRaw)
            return lines.isEmpty ? nil : lines
        } catch {
            NSLog("Niche could not reach qq music: %@", String(describing: error))
            return nil
        }
    }
}

enum KugouClient {
    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let isQueryCJK = LyricsNormalization.hasCJK(title) || LyricsNormalization.hasCJK(artist)
        let query = "\(title) \(artist)"
        var comp = URLComponents(string: "https://songsearch.kugou.com/song_search_v2")!
        comp.queryItems = [
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "pagesize", value: "5")
        ]
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 4)
        req.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = (json["data"] as? [String: Any])?["lists"] as? [[String: Any]] else { return nil }

            let targetCandidate: [String: Any]? = {
                if duration > 0 {
                    return list.first { item in
                        guard let d = item["Duration"] as? Double else { return false }
                        return abs(d - duration) <= 3.5
                    }
                }
                return list.first
            }()

            guard let hash = targetCandidate?["FileHash"] as? String, !hash.isEmpty else { return nil }
            var kComp = URLComponents(string: "https://krcs.kugou.com/search")!
            kComp.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "man", value: "yes"),
                URLQueryItem(name: "client", value: "mobi"),
                URLQueryItem(name: "hash", value: hash)
            ]
            guard let krcUrl = kComp.url else { return nil }

            var krcReq = URLRequest(url: krcUrl, timeoutInterval: 4)
            krcReq.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")
            let (kData, _) = try await URLSession.shared.data(for: krcReq)
            guard let kJson = try JSONSerialization.jsonObject(with: kData) as? [String: Any],
                  let candidates = kJson["candidates"] as? [[String: Any]],
                  let firstCand = candidates.first,
                  let candId = firstCand["id"] as? String,
                  let accesskey = firstCand["accesskey"] as? String else { return nil }
            var dlComp = URLComponents(string: "https://lyrics.kugou.com/download")!
            dlComp.queryItems = [
                URLQueryItem(name: "ver", value: "1"),
                URLQueryItem(name: "client", value: "pc"),
                URLQueryItem(name: "id", value: candId),
                URLQueryItem(name: "accesskey", value: accesskey),
                URLQueryItem(name: "fmt", value: "lrc")
            ]
            guard let dlUrl = dlComp.url else { return nil }

            var dlReq = URLRequest(url: dlUrl, timeoutInterval: 4)
            dlReq.setValue(LyricsService.agent, forHTTPHeaderField: "User-Agent")
            let (dlData, _) = try await URLSession.shared.data(for: dlReq)
            guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
                  let b64 = dlJson["content"] as? String, b64.count < 1_000_000,
                  let rawData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  let lrcText = String(data: rawData, encoding: .utf8) else { return nil }

            if !isQueryCJK && LyricsNormalization.cjkRatio(lrcText) > 0.25 { return nil }
            let lines = LyricsParser.parseLRC(lrcText)
            return lines.isEmpty ? nil : lines
        } catch {
            NSLog("Niche could not reach kugou: %@", String(describing: error))
            return nil
        }
    }
}
