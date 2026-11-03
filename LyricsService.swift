import Foundation

actor LyricsService {
    static let shared = LyricsService()

    func fetch(title: String, artist: String, duration: Double) async -> Lyrics.State {
        // 1. Try LRCLIB with robust search cascade and relaxed duration scoring
        if let lines = await LRCLIBClient.fetch(title: title, artist: artist, duration: duration) {
            let isSynced = lines.contains { $0.time > 0 }
            return .loaded(lines, synced: isSynced)
        }

        // 2. Try Deezer (anonymous catalog provider)
        if let lines = await DeezerClient.fetch(title: title, artist: artist, duration: duration) {
            let isSynced = lines.contains { $0.time > 0 }
            return .loaded(lines, synced: isSynced)
        }

        // 3. Try NetEase (open direct provider)
        if let lines = await NetEaseClient.fetch(title: title, artist: artist, duration: duration) {
            let isSynced = lines.contains { $0.time > 0 }
            return .loaded(lines, synced: isSynced)
        }

        return .missing
    }
}
