import Foundation

enum BoiduClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"

    static func fetch(title: String, artist: String, album: String? = nil, duration: Double) async -> [LyricLine]? {
        let clean = LyricsNormalization.cleanTitle(title)
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist
        let dSec = duration > 0 ? "\(Int(duration.rounded()))" : ""
        let trimmedAlbum = album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveAlbum = (trimmedAlbum?.isEmpty == false) ? trimmedAlbum : nil

        var fallbackLrc: [LyricLine]?
        if let effectiveAlbum {
            let (status, json) = await query(title: clean, artist: primaryArtist, album: effectiveAlbum, durationSec: dSec)
            if status == 200, let json {
                let parsed = parseResponse(json, duration: duration)
                if let ttml = parsed.ttmlLines {
                    return ttml
                }
                fallbackLrc = parsed.lrcLines
            }
        }

        let (_, json) = await query(title: clean, artist: primaryArtist, album: nil, durationSec: dSec)
        if let json {
            let parsed = parseResponse(json, duration: duration)
            if let ttml = parsed.ttmlLines {
                return ttml
            }
            if let lrc = parsed.lrcLines {
                return lrc
            }
        }
        return fallbackLrc
    }

    private static func query(title: String, artist: String, album: String?, durationSec: String) async -> (statusCode: Int, json: [String: Any]?) {
        guard var comp = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics") else { return (0, nil) }
        var items = [
            URLQueryItem(name: "s", value: title),
            URLQueryItem(name: "a", value: artist)
        ]
        if let album { items.append(URLQueryItem(name: "al", value: album)) }
        if !durationSec.isEmpty { items.append(URLQueryItem(name: "d", value: durationSec)) }
        comp.queryItems = items
        guard let url = comp.url else { return (0, nil) }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (status, nil)
            }
            return (status, json)
        } catch {
            return (0, nil)
        }
    }

    private static func parseResponse(_ json: [String: Any], duration: Double) -> (ttmlLines: [LyricLine]?, lrcLines: [LyricLine]?) {
        var ttmlLines: [LyricLine]?
        if let ttml = json["ttml"] as? String,
           let lines = LyricsWordParser.parseTTML(ttml, expectedDuration: duration > 0 ? duration : nil),
           !lines.isEmpty {
            ttmlLines = lines
        }
        var lrcLines: [LyricLine]?
        if let lrc = (json["syncedLyrics"] ?? json["lyrics"] ?? json["lrc"]) as? String {
            let lines = LyricsParser.parseLRC(lrc)
            if !lines.isEmpty, LyricsWordParser.isValidDuration(lines: lines, duration: duration) {
                lrcLines = lines
            }
        }
        return (ttmlLines, lrcLines)
    }
}

enum LyricsPlusClient {
    private static let agent = "Niche/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"

    static func fetch(title: String, artist: String, album: String? = nil, duration: Double) async -> [LyricLine]? {
        let clean = LyricsNormalization.cleanTitle(title)
        let primaryArtist = LyricsNormalization.artistVariants(artist).first ?? artist

        var comp = URLComponents(string: "https://lyricsplus.binimum.org/v2/lyrics/get")!
        var items = [
            URLQueryItem(name: "title", value: clean),
            URLQueryItem(name: "artist", value: primaryArtist)
        ]
        if let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: "\(Int(duration.rounded()))"))
        }
        comp.queryItems = items
        guard let url = comp.url else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return LyricsWordParser.parseKPOE(data, expectedDuration: duration > 0 ? duration : nil)
        } catch {
            return nil
        }
    }
}
