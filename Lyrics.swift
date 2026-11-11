import AppKit
import CoreAudio
import SwiftUI

@MainActor
@Observable
final class Lyrics {
    enum State: Equatable { case idle, loading, loaded([LyricLine], synced: Bool), missing }

    private(set) var state = State.idle
    private(set) var index: Int?
    private(set) var secondaryIndex: Int?
    private(set) var isSinging = false
    private(set) var loadToken: Int = 0
    private(set) var offset: Double = 0.0
    private(set) var hardwareLead: Double = 0.08
    let displayLead: Double = 0.28
    let sweepLead: Double = 0.08
    var lead: Double { hardwareLead + sweepLead }
    @ObservationIgnored var positionProvider: (() -> Double)?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var measured = (text: "", width: CGFloat(0))

    private static let userOffsetsKey = "lyrics_user_offsets"
    private static let resize = Animation.spring(response: 0.45, dampingFraction: 0.95)
    static let closedFont = closedNSFont()

    static func closedNSFont(size: CGFloat = 11.5) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    init() {
        Self.purgeLegacyOffsets()
    }

    var line: String {
        guard case .loaded(let lines, let synced) = state, !lines.isEmpty else { return "" }
        guard synced else { return lines.first?.text ?? "" }
        guard let index, isSinging, index < lines.count, !lines[index].text.isEmpty else { return "♪" }
        return lines[index].text
    }

    var activeLine: LyricLine? {
        guard case .loaded(let lines, true) = state,
              let index, isSinging, index < lines.count else { return nil }
        return lines[index]
    }

    private var secondaryActiveLine: LyricLine? {
        guard case .loaded(let lines, true) = state,
              let secondaryIndex, isSinging, secondaryIndex < lines.count else { return nil }
        return lines[secondaryIndex]
    }

    var isDuet: Bool {
        guard let p = activeLine, let s = secondaryActiveLine, !s.isBackground else { return false }
        return p.agent != nil && s.agent != nil && p.agent != s.agent
    }

    var lineWidth: CGFloat {
        let text = line
        if text != measured.text {
            measured = (text, ceil((text as NSString).size(withAttributes: [.font: Self.closedFont]).width))
        }
        return measured.width
    }

    func updateTransport(_ transport: UInt32) {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            hardwareLead = 0.10
        case kAudioDeviceTransportTypeAirPlay:
            hardwareLead = 0.35
        default:
            hardwareLead = 0.08
        }
    }

    func adjustOffset(by delta: Double) {
        offset = min(max(offset + delta, -5.0), 5.0)
        saveUserOffset(offset)
    }

    func load(_ track: Track?) {
        guard let track else {
            task?.cancel()
            key = ""
            offset = 0.0
            withAnimation(Self.resize) {
                state = .idle
                index = nil
                secondaryIndex = nil
                isSinging = false
                loadToken &+= 1
            }
            return
        }
        let key = "\(track.artist)|\(track.title)|\(track.album)".lowercased()
        guard key != self.key else { return }
        self.key = key
        self.offset = loadUserOffset(for: key)
        task?.cancel()
        task = Task { [weak self] in
            var cachedHasWordTimings = false
            if let cached = await LyricsCache.shared.get(artist: track.artist, title: track.title, album: track.album, duration: track.duration) {
                guard !Task.isCancelled, let self, self.key == key else { return }
                cachedHasWordTimings = cached.lines.contains { !$0.charTimings.isEmpty }
                self.commitLoaded(cached.lines, synced: cached.synced)
                if cachedHasWordTimings { return }
            } else {
                guard !Task.isCancelled, let self, self.key == key else { return }
                withAnimation(Self.resize) {
                    self.index = nil
                    self.secondaryIndex = nil
                    self.isSinging = false
                    self.state = .loading
                }
            }
            let result = await LyricsService.shared.fetch(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration
            )
            guard !Task.isCancelled, let self, self.key == key else { return }
            if case .loaded(let lines, let synced) = result {
                let fetchedHasWords = lines.contains { !$0.charTimings.isEmpty }
                if fetchedHasWords || !cachedHasWordTimings {
                    await LyricsCache.shared.set(artist: track.artist, title: track.title, album: track.album, duration: track.duration, lines: lines, synced: synced)
                    guard !Task.isCancelled, self.key == key else { return }
                }
                if fetchedHasWords || self.state == .loading {
                    self.commitLoaded(lines, synced: synced)
                }
            } else if self.state == .loading {
                withAnimation(Self.resize) {
                    self.index = nil
                    self.secondaryIndex = nil
                    self.isSinging = false
                    self.state = result
                }
            }
        }
    }

    private func commitLoaded(_ lines: [LyricLine], synced: Bool) {
        withAnimation(Self.resize) {
            index = nil
            secondaryIndex = nil
            isSinging = false
            state = .loaded(lines, synced: synced)
            loadToken &+= 1
        }
        if synced, let pos = positionProvider?() {
            sync(pos)
        }
    }

    func sync(_ position: Double) {
        guard case .loaded(let lines, synced: true) = state, !lines.isEmpty else { return }
        let audioAt = position + hardwareLead + offset
        let (next, nextSecondary, singing) = Self.resolveLines(lines: lines, audioAt: audioAt, displayLead: displayLead)
        guard next != index || nextSecondary != secondaryIndex || singing != isSinging else { return }
        withAnimation(Self.resize) {
            index = next
            secondaryIndex = nextSecondary
            isSinging = singing
        }
    }

    static func resolveLines(
        lines: [LyricLine],
        audioAt: Double,
        displayLead: Double = 0.28
    ) -> (primary: Int?, secondary: Int?, singing: Bool) {
        guard !lines.isEmpty, audioAt >= lines[0].time - displayLead else {
            return (nil, nil, false)
        }
        if audioAt < lines[0].time { return (0, nil, true) }
        let active = lines.indices.filter { lines[$0].time <= audioAt + 0.08 && audioAt < lines[$0].end }
        if active.count >= 2 {
            let primary = active.first { !lines[$0].isBackground } ?? active[0]
            let secondary = active.filter { c in
                guard c != primary else { return false }
                let overlap = min(lines[primary].end, lines[c].end) - max(lines[primary].time, lines[c].time)
                return overlap >= (lines[c].isBackground ? 0.20 : 0.35)
            }.max { a, b in
                if lines[a].isBackground != lines[b].isBackground { return lines[a].isBackground }
                return (lines[a].time, a) < (lines[b].time, b)
            }
            if let secondary { return (primary, secondary, true) }
        }
        if !active.isEmpty {
            let only = active.first { !lines[$0].isBackground } ?? active[0]
            let future = ((only + 1)..<lines.count).first { lines[$0].end > audioAt && lines[$0].time >= lines[only].time }
            if let future {
                let nextTime = lines[future].time
                let earliestSwitch = max(min(lines[only].end, nextTime), nextTime - displayLead)
                if audioAt < earliestSwitch { return (only, nil, true) }
            } else if audioAt < lines[only].end + 2.0 {
                return (only, nil, true)
            }
        }
        let ended = lines.indices.filter { lines[$0].end <= audioAt }
        let prevIdx = ended.max { a, b in (lines[a].end, a) < (lines[b].end, b) }
        let prevTime = prevIdx.map { lines[$0].time } ?? -1.0
        let nextIdx = lines.indices.first { lines[$0].end > audioAt && lines[$0].time > prevTime }
            ?? lines.indices.first { lines[$0].end > audioAt }
        if let nextIdx {
            let nextTime = lines[nextIdx].time
            guard let prevIdx else { return (nextIdx, nil, true) }
            if nextTime - lines[prevIdx].end > 3.0 {
                if audioAt < min(nextTime - displayLead, lines[prevIdx].end + 1.0) { return (prevIdx, nil, true) }
                return audioAt < nextTime - displayLead ? (prevIdx, nil, false) : (nextIdx, nil, true)
            }
            return (audioAt < nextTime - displayLead ? prevIdx : nextIdx, nil, true)
        }
        let lastIdx = lines.indices.max { a, b in (lines[a].end, a) < (lines[b].end, b) } ?? (lines.count - 1)
        return (lastIdx, nil, audioAt < lines[lastIdx].end + 2.0)
    }

    private func loadUserOffset(for key: String) -> Double {
        let all = UserDefaults.standard.dictionary(forKey: Self.userOffsetsKey) as? [String: Double]
        return all?[key] ?? 0.0
    }

    private func saveUserOffset(_ val: Double) {
        guard !key.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.userOffsetsKey) as? [String: Double] ?? [:]
        if abs(val) < 0.005 {
            all.removeValue(forKey: key)
        } else {
            all[key] = val
        }
        UserDefaults.standard.set(all, forKey: Self.userOffsetsKey)
    }

    private static func purgeLegacyOffsets() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "niche_device_latency_store")
        let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("lyrics_offset_") }
        guard !legacyKeys.isEmpty else { return }
        for k in legacyKeys { defaults.removeObject(forKey: k) }
    }
}

