import Foundation

enum YouTubeMusicClient {
    private static let searchURL = URL(string: "https://music.youtube.com/youtubei/v1/search?prettyPrint=false")!
    private static let nextURL = URL(string: "https://music.youtube.com/youtubei/v1/next?prettyPrint=false")!
    private static let browseURL = URL(string: "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false")!

    static func fetch(title: String, artist: String, duration: Double) async -> [LyricLine]? {
        let cleanTitle = LyricsNormalization.cleanTitle(title)
        guard !Task.isCancelled, !cleanTitle.isEmpty, duration.isFinite, duration >= 0 else { return nil }
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = [cleanTitle, primaryArtist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty,
              let videoId = await searchVideoId(query: query, title: cleanTitle, artist: artist, duration: duration) else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let browseId = await fetchLyricsBrowseId(videoId: videoId) else { return nil }
        guard !Task.isCancelled else { return nil }
        return await fetchTimedLyrics(browseId: browseId)
    }

    private static func searchVideoId(query: String, title: String, artist: String, duration: Double) async -> String? {
        let body: [String: Any] = ["context": webContext(), "query": query, "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA=="]
        guard let json = await postJSON(url: searchURL, body: body, headers: webHeaders()) else { return nil }
        let targetTitle = norm(LyricsNormalization.cleanTitle(title))
        let targetArtists = LyricsNormalization.artistVariants(artist).map(norm).filter { !$0.isEmpty }
        var rows: [[String: Any]] = []
        walkDicts(in: json) { dict in
            if rows.count >= 8 { return false }
            guard let row = dict["musicResponsiveListItemRenderer"] as? [String: Any] else { return true }
            rows.append(row)
            return false
        }
        for row in rows {
            let pid = (row["playlistItemData"] as? [String: Any])?["videoId"] as? String
            let nav = ((row["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
            guard let videoId = pid.flatMap({ $0.isEmpty ? nil : $0 }) ?? nav.flatMap({ $0.isEmpty ? nil : $0 }),
                  let cols = row["flexColumns"] as? [[String: Any]], cols.count >= 2 else { continue }
            let rowTitle = norm(LyricsNormalization.cleanTitle(columnRuns(cols[0]).joined()))
            guard !rowTitle.isEmpty, titleMatches(rowTitle, targetTitle) else { continue }
            let subtitleRuns = columnRuns(cols[1])
            if !targetArtists.isEmpty, !artistMatches(subtitleRuns: subtitleRuns, targetArtists: targetArtists) { continue }
            if duration > 0 {
                guard let itemDur = extractDuration(from: subtitleRuns), abs(itemDur - duration) <= 5.0 else { continue }
            }
            return videoId
        }
        return nil
    }

    private static func fetchLyricsBrowseId(videoId: String) async -> String? {
        let body: [String: Any] = ["context": webContext(), "videoId": videoId, "isAudioOnly": true]
        guard let json = await postJSON(url: nextURL, body: body, headers: webHeaders()) else { return nil }
        return find(in: json) { dict -> String? in
            guard let ep = dict["browseEndpoint"] as? [String: Any],
                  let cfg = (ep["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any],
                  cfg["pageType"] as? String == "MUSIC_PAGE_TYPE_TRACK_LYRICS",
                  let id = ep["browseId"] as? String, !id.isEmpty else { return nil }
            return id
        }
    }

    private static func fetchTimedLyrics(browseId: String) async -> [LyricLine]? {
        let iosCtx: [String: Any] = ["client": ["clientName": "IOS_MUSIC", "clientVersion": "7.01.05"]]
        let headers = ["X-YouTube-Client-Name": "26", "X-YouTube-Client-Version": "7.01.05", "User-Agent": LyricsService.agent]
        guard let json = await postJSON(url: browseURL, body: ["context": iosCtx, "browseId": browseId], headers: headers),
              let timedData = find(in: json, match: { ($0["timedLyricsData"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 } }) else {
            return nil
        }
        return parseTimedLyrics(timedData)
    }

    static func parseTimedLyrics(_ items: [[String: Any]]) -> [LyricLine]? {
        var raw: [(time: Double, end: Double?, text: String)] = []
        for item in items {
            let text = (item["lyricLine"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, !LyricsWordParser.isMetadataOrJunkLine(text),
                  let cueRange = item["cueRange"] as? [String: Any],
                  let startMs = parseMs(cueRange["startTimeMilliseconds"]) else { continue }
            let time = startMs / 1000.0
            let parsedEnd = parseMs(cueRange["endTimeMilliseconds"]).map { $0 / 1000.0 }
            raw.append((time: time, end: parsedEnd.flatMap { $0 > time ? $0 : nil }, text: text))
        }
        guard !raw.isEmpty else { return nil }
        if raw.count >= 2, raw.allSatisfy({ $0.time == raw[0].time }) { return nil }
        let sorted = raw.sorted { $0.time < $1.time }
        return sorted.indices.map { i in
            let item = sorted[i]
            let fallbackEnd: Double
            if i + 1 < sorted.count {
                let next = sorted[i + 1].time
                fallbackEnd = next - item.time <= 5.0
                    ? max(item.time + 0.1, next)
                    : min(next - 1.5, item.time + max(2.5, min(6.0, Double(item.text.count) * 0.08 + 1.5)))
            } else { fallbackEnd = item.time + 4.0 }
            return LyricLine(id: i, time: item.time, end: item.end ?? fallbackEnd, text: item.text)
        }
    }

    private static func postJSON(url: URL, body: [String: Any], headers: [String: String]) async -> [String: Any]? {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            NSLog("Niche could not reach youtube music: %@", String(describing: error))
            return nil
        }
    }

    private static func webContext() -> [String: Any] { ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20260213.01.00"]] }
    private static func webHeaders() -> [String: String] {
        ["X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": "1.20260213.01.00", "Origin": "https://music.youtube.com", "User-Agent": LyricsService.agent]
    }

    private static func columnRuns(_ col: [String: Any]) -> [String] {
        let r = col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] ?? col
        return ((r["text"] as? [String: Any])?["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }

    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titleMatches(_ row: String, _ target: String) -> Bool {
        row == target || [" - ", " feat.", " feat ", " ft.", " ft "].contains { row.hasPrefix(target + $0) || target.hasPrefix(row + $0) }
    }

    private static func artistMatches(subtitleRuns: [String], targetArtists: [String]) -> Bool {
        let parts = subtitleRuns.joined().components(separatedBy: " • ")
        let raw = (parts.count >= 2 && ["song", "video"].contains(parts[0].trimmingCharacters(in: .whitespaces).lowercased()))
            ? parts[1] : (parts.first ?? "")
        var rowArtists = LyricsNormalization.artistVariants(raw).map(norm).filter { !$0.isEmpty }
        let whole = norm(raw)
        if !whole.isEmpty, !rowArtists.contains(whole) { rowArtists.insert(whole, at: 0) }
        return targetArtists.contains { t in rowArtists.contains { $0 == t || (min($0.count, t.count) >= 4 && ($0.contains(t) || t.contains($0))) } }
    }

    private static func extractDuration(from subtitleRuns: [String]) -> Double? {
        for text in subtitleRuns.reversed() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.range(of: #"^\d+:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil,
               let sec = LyricsWordParser.parseTimeSeconds(t) { return sec }
        }
        return nil
    }

    private static func walkDicts(in node: Any, visit: ([String: Any]) -> Bool) {
        if let dict = node as? [String: Any] {
            guard visit(dict) else { return }
            for key in dict.keys.sorted() { walkDicts(in: dict[key]!, visit: visit) }
        } else if let arr = node as? [Any] {
            for val in arr { walkDicts(in: val, visit: visit) }
        }
    }

    private static func find<T>(in node: Any, match: ([String: Any]) -> T?) -> T? {
        if let dict = node as? [String: Any] {
            if let hit = match(dict) { return hit }
            for key in dict.keys.sorted() { if let hit = find(in: dict[key]!, match: match) { return hit } }
        } else if let arr = node as? [Any] {
            for val in arr { if let hit = find(in: val, match: match) { return hit } }
        }
        return nil
    }

    private static func parseMs(_ value: Any?) -> Double? {
        let v: Double? = (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? ((value as? NSNumber).flatMap { (value is Bool) ? nil : $0.doubleValue })
        guard let v, v.isFinite, v >= 0, v < 86_400_000 else { return nil }
        return v
    }
}
