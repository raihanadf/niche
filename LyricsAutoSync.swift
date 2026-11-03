import Foundation

@MainActor
final class LyricsAutoSync {
    private weak var spectrum: AudioSpectrum?
    private weak var lyrics: Lyrics?
    private var currentTrack: Track?
    private var currentKey = ""
    private var isCalibrated = false
    private var isListening = false
    private var analyzer: VocalActivityAnalyzer?
    private var alignTask: Task<Void, Never>?

    nonisolated static let targetDurationSec = 25.0
    nonisolated static let minConfidence: Float = 0.40

    init(spectrum: AudioSpectrum, lyrics: Lyrics) {
        self.spectrum = spectrum
        self.lyrics = lyrics
    }

    func trackChanged(to track: Track?) {
        alignTask?.cancel()
        alignTask = nil
        stopListening()
        analyzer = nil
        currentTrack = track

        guard let track else {
            currentKey = ""
            isCalibrated = false
            return
        }
        let key = "lyrics_offset_\(track.artist)_\(track.title)"
        currentKey = key

        if UserDefaults.standard.object(forKey: key) != nil {
            lyrics?.setOffset(UserDefaults.standard.double(forKey: key))
            isCalibrated = true
        } else {
            isCalibrated = false
            analyzer = VocalActivityAnalyzer()
        }
    }

    func update(isPlaying: Bool, position: Double) {
        guard !isCalibrated, currentTrack != nil else { return }
        if !isPlaying || position >= Self.targetDurationSec {
            if isListening { finishAndAlign() }
            return
        }
        if !isListening { startListening() }
    }

    private func startListening() {
        guard !isListening, let spectrum, let analyzer else { return }
        isListening = true
        spectrum.onPcmSamples = { [weak self, weak analyzer] samples, channels, sampleRate in
            guard let analyzer else { return }
            if analyzer.feed(samples, channels: channels, sampleRate: sampleRate) {
                Task { @MainActor [weak self] in self?.finishAndAlign() }
            }
        }
    }

    private func stopListening() {
        guard isListening else { return }
        isListening = false
        spectrum?.onPcmSamples = nil
    }

    private func finishAndAlign() {
        stopListening()
        guard let analyzer = self.analyzer, let track = self.currentTrack else { return }
        self.analyzer = nil
        let key = currentKey
        var existingLines: [LyricLine]?
        if case .loaded(let lines, true) = lyrics?.state { existingLines = lines }

        alignTask = Task.detached { [weak self] in
            guard let vocals = analyzer.finish() else { return }
            var lines = existingLines
            if lines == nil {
                let fetched = await LyricsService.shared.fetch(title: track.title, artist: track.artist, duration: track.duration)
                if case .loaded(let l, true) = fetched { lines = l }
            }
            guard !Task.isCancelled, let lines,
                  let alignment = LyricsAligner.align(lines: lines, vocals: vocals),
                  alignment.confidence >= Self.minConfidence else { return }

            let offsetSec = Double(alignment.offsetMs) / 1000.0
            UserDefaults.standard.set(offsetSec, forKey: key)
            await self?.applyAlignment(offsetSec: offsetSec, key: key)
        }
    }

    private func applyAlignment(offsetSec: Double, key: String) {
        guard currentKey == key else { return }
        isCalibrated = true
        lyrics?.setOffset(offsetSec)
    }
}
