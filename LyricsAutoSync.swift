import Foundation

enum LyricsAutoSyncStorage {
    static func key(artist: String, title: String) -> String {
        let cleanArtist = artist.trimmingCharacters(in: .whitespaces).lowercased()
        let cleanTitle = title.trimmingCharacters(in: .whitespaces).lowercased()
        return "lyrics_offset_\(cleanArtist)|\(cleanTitle)"
    }

    static func loadOffset(artist: String, title: String) -> Double? {
        let k = key(artist: artist, title: title)
        guard UserDefaults.standard.object(forKey: k) != nil else { return nil }
        return UserDefaults.standard.double(forKey: k)
    }

    static func saveOffset(_ offset: Double, artist: String, title: String) {
        let k = key(artist: artist, title: title)
        UserDefaults.standard.set(offset, forKey: k)
    }
}

@MainActor
final class LyricsAutoSync {
    enum State: Equatable {
        case idle, cached(Double), listening, calibrated(Double), timedOut
    }

    private(set) var state: State = .idle
    private var positionProvider: (() -> Double)?
    private var onCalibrated: ((Double) -> Void)?
    private weak var spectrum: AudioSpectrum?

    private var currentSongKey: String?
    private var currentArtist: String?
    private var currentTitle: String?
    private var activeLines: [LyricLine] = []
    private var hasSyncedLyrics = false
    private var listeningStartPos: Double = 0
    private struct TimeAnchor: Sendable {
        let elapsed: Double
        let date: Date
        let rate: Double
        let isPlaying: Bool
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var isListening = false
    nonisolated(unsafe) private var timeAnchor = TimeAnchor(elapsed: 0, date: Date(), rate: 1, isPlaying: false)
    nonisolated(unsafe) private var recordedSamples: [(time: Double, onset: Float)] = []
    private let maxSampleCount = 2000

    func bind(position: @escaping () -> Double, spectrum: AudioSpectrum, onCalibrated: @escaping (Double) -> Void) {
        self.positionProvider = position
        self.spectrum = spectrum
        self.onCalibrated = onCalibrated
    }

    func songChanged(artist: String, title: String) {
        let key = LyricsAutoSyncStorage.key(artist: artist, title: title)
        guard currentSongKey != key else { return }
        reset()
        currentSongKey = key
        currentArtist = artist
        currentTitle = title

        if let cached = LyricsAutoSyncStorage.loadOffset(artist: artist, title: title) {
            state = .cached(cached)
            onCalibrated?(cached)
            return
        }

        onCalibrated?(0.0)
        checkStartListening()
    }

    func lyricsLoaded(_ lines: [LyricLine], synced: Bool) {
        activeLines = lines
        hasSyncedLyrics = synced
        checkStartListening()
    }

    func updateTimeAnchor(elapsed: Double, date: Date, rate: Double, isPlaying: Bool) {
        lock.lock()
        timeAnchor = TimeAnchor(elapsed: elapsed, date: date, rate: rate, isPlaying: isPlaying)
        lock.unlock()
    }

    func tick(position: Double) {
        guard case .listening = state else { return }
        guard hasSyncedLyrics, !activeLines.isEmpty else { return }

        let elapsed = max(0, position - listeningStartPos)
        let pastCount = activeLines.filter { $0.time >= listeningStartPos && position >= $0.end }.count
        let readyToAlign = (pastCount >= 2 && elapsed >= 8.0) || elapsed >= 16.0

        if readyToAlign {
            evaluateAlignment(at: position)
        } else if elapsed >= 25.0 || position >= 75.0 {
            deactivate(as: .timedOut)
        }
    }

    private func checkStartListening() {
        guard case .idle = state, currentSongKey != nil, hasSyncedLyrics, !activeLines.isEmpty else { return }
        let currentPos = positionProvider?() ?? 0
        guard currentPos <= 45.0 else {
            deactivate(as: .timedOut)
            return
        }
        startListening()
    }

    private func startListening() {
        state = .listening
        listeningStartPos = positionProvider?() ?? 0
        lock.lock()
        isListening = true
        recordedSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        guard let spectrum else { return }
        spectrum.onVocalSample = { [weak self] onset in
            self?.recordSample(onset)
        }
        spectrum.isVocalSyncActive = true
    }

    nonisolated private func recordSample(_ onset: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard isListening, recordedSamples.count < maxSampleCount else { return }
        let anchor = timeAnchor
        guard anchor.isPlaying else { return }
        let live = Date().timeIntervalSince(anchor.date) * anchor.rate
        let time = max(0, anchor.elapsed + live)
        recordedSamples.append((time: time, onset: onset))
    }

    private func evaluateAlignment(at position: Double) {
        lock.lock()
        let samples = recordedSamples
        lock.unlock()

        let elapsed = max(0, position - listeningStartPos)
        guard samples.count >= 60 else {
            if elapsed >= 25.0 || position >= 75.0 { deactivate(as: .timedOut) }
            return
        }

        if let result = LyricsAligner.align(lines: activeLines, heardOnsets: samples) {
            applyCalibration(result.offset)
        } else if elapsed >= 25.0 || position >= 75.0 {
            deactivate(as: .timedOut)
        }
    }

    private func applyCalibration(_ offset: Double) {
        guard let artist = currentArtist, let title = currentTitle else { return }
        let roundedOffset = (offset * 20.0).rounded() / 20.0
        LyricsAutoSyncStorage.saveOffset(roundedOffset, artist: artist, title: title)
        onCalibrated?(roundedOffset)
        deactivate(as: .calibrated(roundedOffset))
    }

    private func deactivate(as finalState: State) {
        state = finalState
        lock.lock()
        isListening = false
        recordedSamples.removeAll(keepingCapacity: false)
        lock.unlock()
        if let spectrum {
            spectrum.isVocalSyncActive = false
            spectrum.onVocalSample = nil
        }
    }

    func reset() {
        deactivate(as: .idle)
        currentSongKey = nil
        currentArtist = nil
        currentTitle = nil
        activeLines = []
        hasSyncedLyrics = false
        listeningStartPos = 0
    }
}
