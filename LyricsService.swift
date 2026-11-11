import Foundation

enum LyricsSource: String, CaseIterable, Sendable {
    case automatic, boidu, lyricsPlus, lrclib, youtubeMusic, unison, netease, qqMusic, kugou, deezer

    var name: String {
        switch self {
        case .automatic: "Automatic"
        case .boidu: "Boidu (Apple Music)"
        case .lyricsPlus: "LyricsPlus"
        case .lrclib: "LRCLIB"
        case .youtubeMusic: "YouTube Music"
        case .unison: "Unison"
        case .netease: "NetEase"
        case .qqMusic: "QQ Music"
        case .kugou: "Kugou"
        case .deezer: "Deezer"
        }
    }
}

actor LyricsService {
    static let shared = LyricsService()
    static let agent = "Niche/\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String) (https://github.com/raihanadf/niche)"

    func fetch(title: String, artist: String, album: String? = nil, duration: Double, source: LyricsSource) async -> Lyrics.State {
        guard !Task.isCancelled,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, duration >= 0 else { return .missing }

        let lines: [LyricLine]?
        switch source {
        case .automatic: return await automatic(title: title, artist: artist, album: album, duration: duration)
        case .boidu: lines = await BoiduClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .lyricsPlus: lines = await LyricsPlusClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .lrclib: lines = await LRCLIBClient.fetch(title: title, artist: artist, album: album, duration: duration)
        case .youtubeMusic: lines = await YouTubeMusicClient.fetch(title: title, artist: artist, duration: duration)
        case .unison: lines = await UnisonClient.fetch(title: title, artist: artist, duration: duration)
        case .netease: lines = await NetEaseClient.fetch(title: title, artist: artist, duration: duration)
        case .qqMusic: lines = await QQMusicClient.fetch(title: title, artist: artist, duration: duration)
        case .kugou: lines = await KugouClient.fetch(title: title, artist: artist, duration: duration)
        case .deezer: lines = await DeezerClient.fetch(title: title, artist: artist, duration: duration)
        }
        guard !Task.isCancelled, let lines else { return .missing }
        if isValidSynced(lines, duration: duration) { return .loaded(lines, synced: true) }
        return isValidPlain(lines, duration: duration) ? .loaded(lines, synced: false) : .missing
    }

    private func automatic(title: String, artist: String, album: String?, duration: Double) async -> Lyrics.State {
        async let boidu = BoiduClient.fetch(title: title, artist: artist, album: album, duration: duration)
        async let lyricsPlus = LyricsPlusClient.fetch(title: title, artist: artist, album: album, duration: duration)
        let (bLines, lpLines) = await (boidu, lyricsPlus)
        guard !Task.isCancelled else { return .missing }

        if let bLines, isWordTimed(bLines, duration: duration) {
            return .loaded(bLines, synced: true)
        }
        if let lpLines, isWordTimed(lpLines, duration: duration) {
            return .loaded(lpLines, synced: true)
        }

        var lLines: [LyricLine]?
        var yLines: [LyricLine]?
        let uLines: [LyricLine]?
        let nLines: [LyricLine]?
        if isValidSynced(bLines, duration: duration) || isValidSynced(lpLines, duration: duration) {
            async let unison = UnisonClient.fetch(title: title, artist: artist, duration: duration)
            async let netease = NetEaseClient.fetch(title: title, artist: artist, duration: duration)
            (uLines, nLines) = await (unison, netease)
        } else {
            async let lrclib = LRCLIBClient.fetch(title: title, artist: artist, album: album, duration: duration)
            async let ytm = YouTubeMusicClient.fetch(title: title, artist: artist, duration: duration)
            async let unison = UnisonClient.fetch(title: title, artist: artist, duration: duration)
            async let netease = NetEaseClient.fetch(title: title, artist: artist, duration: duration)
            (lLines, yLines, uLines, nLines) = await (lrclib, ytm, unison, netease)
        }
        guard !Task.isCancelled else { return .missing }

        if let uLines, isWordTimed(uLines, duration: duration) {
            return .loaded(uLines, synced: true)
        }
        if let nLines, isWordTimed(nLines, duration: duration) {
            return .loaded(nLines, synced: true)
        }

        for lines in [bLines, lpLines, lLines, yLines, uLines, nLines].compactMap({ $0 })
            where isValidSynced(lines, duration: duration) {
            return .loaded(lines, synced: true)
        }

        async let qq = QQMusicClient.fetch(title: title, artist: artist, duration: duration)
        async let kugou = KugouClient.fetch(title: title, artist: artist, duration: duration)
        let (qLines, kLines) = await (qq, kugou)
        guard !Task.isCancelled else { return .missing }

        for lines in [qLines, kLines].compactMap({ $0 })
            where isValidSynced(lines, duration: duration) {
            return .loaded(lines, synced: true)
        }

        let dLines = await DeezerClient.fetch(title: title, artist: artist, duration: duration)
        guard !Task.isCancelled else { return .missing }
        if let dLines, isValidSynced(dLines, duration: duration) {
            return .loaded(dLines, synced: true)
        }

        for fallback in [bLines, lpLines, lLines, yLines, uLines, nLines, qLines, kLines, dLines].compactMap({ $0 })
            where isValidPlain(fallback, duration: duration) {
            return .loaded(fallback, synced: false)
        }

        return .missing
    }

    private func hasRealSync(_ lines: [LyricLine]) -> Bool {
        lines.contains { $0.time.isFinite && $0.time > 0 && $0.time < 86_400 } &&
            (lines.count < 2 || Set(lines.compactMap { ($0.time.isFinite && $0.time >= 0 && $0.time < 86_400) ? Int($0.time * 10) : nil }).count > 1)
    }

    private func isValidPlain(_ lines: [LyricLine], duration: Double) -> Bool {
        guard !lines.isEmpty,
              lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LyricsWordParser.isMetadataOrJunkLine($0.text) }) else {
            return false
        }
        return !hasRealSync(lines) || LyricsWordParser.isValidDuration(lines: lines, duration: duration)
    }

    private func isValidSynced(_ lines: [LyricLine]?, duration: Double) -> Bool {
        guard let lines, LyricsWordParser.isValidDuration(lines: lines, duration: duration) else { return false }
        return hasRealSync(lines)
    }

    private func isWordTimed(_ lines: [LyricLine]?, duration: Double) -> Bool {
        guard let lines, isValidSynced(lines, duration: duration) else { return false }
        return lines.contains { !$0.charTimings.isEmpty }
    }
}
