import Foundation

actor LyricsService {
    static let shared = LyricsService()

    func fetch(title: String, artist: String, duration: Double) async -> Lyrics.State {
        async let lrclib = LRCLIBClient.fetch(title: title, artist: artist, duration: duration)
        async let deezer = DeezerClient.fetch(title: title, artist: artist, duration: duration)
        let (lLines, dLines) = await (lrclib, deezer)

        let lSynced = lLines?.contains { $0.time > 0 } == true
        let dSynced = dLines?.contains { $0.time > 0 } == true

        if let lLines, let dLines, lSynced, dSynced {
            let lDur = lLines.last?.end ?? 0
            let dDur = dLines.last?.end ?? 0
            let lDiff = abs(lDur - duration)
            let dDiff = abs(dDur - duration)
            return .loaded(dDiff <= lDiff ? dLines : lLines, synced: true)
        }

        if let dLines, dSynced { return .loaded(dLines, synced: true) }
        if let lLines, lSynced { return .loaded(lLines, synced: true) }

        if let lines = await NetEaseClient.fetch(title: title, artist: artist, duration: duration) {
            let isSynced = lines.contains { $0.time > 0 }
            return .loaded(lines, synced: isSynced)
        }

        if let dLines { return .loaded(dLines, synced: false) }
        if let lLines { return .loaded(lLines, synced: false) }

        return .missing
    }
}
