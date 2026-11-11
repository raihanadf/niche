import CryptoKit
import Foundation

struct CachedLyrics: Codable, Sendable {
    let version: Int, lines: [LyricLine], synced: Bool, savedAt: Date
    init(version: Int = 4, lines: [LyricLine], synced: Bool, savedAt: Date) {
        self.version = version; self.lines = lines; self.synced = synced; self.savedAt = savedAt
    }
}

actor LyricsCache {
    static let shared = LyricsCache()

    private let maxMemoryEntries: Int, maxDiskBytes: Int64, targetDiskBytes: Int64, maxAge: TimeInterval

    private var memoryCache: [String: CachedLyrics] = [:]
    private var memoryOrder: [String] = []
    private let fm: FileManager
    private let folderURL: URL

    init(folderURL: URL? = nil, maxMemoryEntries: Int = 20, maxDiskBytes: Int64 = 30 * 1024 * 1024,
         targetDiskBytes: Int64 = 20 * 1024 * 1024, maxAge: TimeInterval = 60 * 86_400) {
        let manager = FileManager()
        let base = folderURL ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("local.niche/Lyrics", isDirectory: true)
        self.fm = manager; self.folderURL = base; self.maxMemoryEntries = maxMemoryEntries
        self.maxDiskBytes = maxDiskBytes; self.targetDiskBytes = targetDiskBytes; self.maxAge = maxAge
        try? fm.createDirectory(at: self.folderURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func get(artist: String, title: String, album: String = "", duration: Double = 0) async -> (lines: [LyricLine], synced: Bool)? {
        let key = cacheKey(artist: artist, title: title, album: album, duration: duration)
        let now = Date()

        if let item = memoryCache[key] {
            if !isCacheValid(item) {
                evictMemory(key: key)
                try? fm.removeItem(at: fileURL(for: key))
                return nil
            }
            touchMemory(key: key)
            return (item.lines, item.synced)
        }
        let url = fileURL(for: key)
        guard fm.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let item = try? JSONDecoder().decode(CachedLyrics.self, from: data) else {
            try? fm.removeItem(at: url)
            return nil
        }

        if !isCacheValid(item) {
            try? fm.removeItem(at: url)
            return nil
        }

        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: url.path(percentEncoded: false))
        remember(key: key, item: item)
        return (item.lines, item.synced)
    }

    func set(artist: String, title: String, album: String = "", duration: Double = 0, lines: [LyricLine], synced: Bool) async {
        guard !lines.isEmpty, lines.contains(where: { !LyricsWordParser.isMetadataOrJunkLine($0.text) }) else { return }
        let key = cacheKey(artist: artist, title: title, album: album, duration: duration)
        let item = CachedLyrics(version: 4, lines: lines, synced: synced, savedAt: Date())
        guard let data = try? JSONEncoder().encode(item), data.count <= 1_048_576 else { return }
        remember(key: key, item: item)

        let url = fileURL(for: key)
        try? fm.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)

        pruneDisk()
    }

    private func pruneDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return }

        let now = Date()
        var totalBytes: Int64 = 0
        var files: [(url: URL, date: Date, size: Int64)] = []

        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            if now.timeIntervalSince(date) > maxAge {
                try? fm.removeItem(at: url)
                continue
            }
            let fileSize = Int64(size)
            totalBytes += fileSize
            files.append((url: url, date: date, size: fileSize))
        }

        if totalBytes > maxDiskBytes {
            files.sort { $0.date < $1.date }
            for file in files {
                if (try? fm.removeItem(at: file.url)) != nil {
                    totalBytes -= file.size
                    if totalBytes <= targetDiskBytes { break }
                }
            }
        }
    }

    private func cacheKey(artist: String, title: String, album: String, duration: Double) -> String {
        let roundedDur = (duration.isFinite && duration >= 0 && duration < 86_400) ? Int(duration.rounded()) : 0
        let raw = "\(artist)|\(title)|\(album)|\(roundedDur)".lowercased()
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL {
        folderURL.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func touchMemory(key: String) {
        if let idx = memoryOrder.firstIndex(of: key) {
            memoryOrder.remove(at: idx)
        }
        memoryOrder.append(key)
    }

    private func remember(key: String, item: CachedLyrics) {
        memoryCache[key] = item
        touchMemory(key: key)
        while memoryOrder.count > maxMemoryEntries {
            let oldest = memoryOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    private func evictMemory(key: String) {
        memoryCache.removeValue(forKey: key)
        memoryOrder.removeAll { $0 == key }
    }
    private func isCacheValid(_ item: CachedLyrics) -> Bool {
        guard item.version == 4, !item.lines.isEmpty else { return false }
        guard abs(Date().timeIntervalSince(item.savedAt)) <= maxAge else { return false }
        return item.lines.contains { !LyricsWordParser.isMetadataOrJunkLine($0.text) }
    }
}
