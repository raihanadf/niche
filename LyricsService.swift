import Foundation

actor LyricsService {
    static let shared = LyricsService()

    func fetch(title: String, artist: String, album: String? = nil, duration: Double) async -> Lyrics.State {
        guard !Task.isCancelled,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite, duration >= 0 else { return .missing }

        // Tier 1: Word-by-Word (#1 Boidu -> #2 LyricsPlus)
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

        // Stage 2: Race remaining word-timed capable (#5 Unison, #6 NetEase) & synced providers
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

        // Stage 3: Regional Asian Catalogues (#7 QQ Music -> #8 Kugou)
        async let qq = QQMusicClient.fetch(title: title, artist: artist, duration: duration)
        async let kugou = KugouClient.fetch(title: title, artist: artist, duration: duration)
        let (qLines, kLines) = await (qq, kugou)
        guard !Task.isCancelled else { return .missing }

        for lines in [qLines, kLines].compactMap({ $0 })
            where isValidSynced(lines, duration: duration) {
            return .loaded(lines, synced: true)
        }

        // Tier 4: Deezer #9 & Plain-text fallback
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
