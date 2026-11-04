import AppKit
import CoreAudio
import SwiftUI

@MainActor
@Observable
final class Lyrics {
    enum State: Equatable { case idle, loading, loaded([LyricLine], synced: Bool), missing }

    private(set) var state = State.idle
    private(set) var index: Int?
    private(set) var isSinging = true
    private(set) var offset: Double = 0.0
    private(set) var lead: Double = 0.05
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var measured = (text: "", width: CGFloat(0))

    private static let userOffsetsKey = "lyrics_user_offsets"
    private static let resize = Animation.spring(response: 0.45, dampingFraction: 0.95)
    static let closedFont = NSFont(descriptor: NSFont.systemFont(ofSize: 11.5, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 11.5)!

    init() {
        Self.purgeLegacyOffsets()
    }

    var line: String {
        guard case .loaded(let lines, let synced) = state else { return "" }
        guard synced else { return lines[0].text }
        guard let index, isSinging, !lines[index].text.isEmpty else { return "♪" }
        return lines[index].text
    }

    var activeLine: LyricLine? {
        guard case .loaded(let lines, true) = state,
              let index, isSinging, index < lines.count else { return nil }
        return lines[index]
    }

    var lineWidth: CGFloat {
        let text = line
        if text != measured.text {
            measured = (text, ceil((text as NSString).size(withAttributes: [.font: Self.closedFont]).width))
        }
        return measured.width
    }

    func updateTransport(_ transport: UInt32, measuredLatency: Double? = nil) {
        if let measuredLatency, measuredLatency > 0 {
            lead = measuredLatency
            return
        }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            lead = 0.22
        case kAudioDeviceTransportTypeAirPlay:
            lead = 0.45
        default:
            lead = 0.05
        }
    }

    func setOffset(_ val: Double) {
        offset = min(max(val, -5.0), 5.0)
        saveUserOffset(offset)
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
            }
            return
        }
        let key = "\(track.artist)|\(track.title)".lowercased()
        guard key != self.key else { return }
        self.key = key
        self.offset = loadUserOffset(for: key)
        task?.cancel()
        withAnimation(Self.resize) {
            index = nil
            if let cached = cache[key] {
                state = cached
            } else {
                state = .loading
            }
        }
        guard state == .loading else { return }
        task = Task { [weak self] in
            let result = await LyricsService.shared.fetch(title: track.title, artist: track.artist, duration: track.duration)
            guard !Task.isCancelled, let self, self.key == key else { return }
            if case .loaded = result {
                if self.cache.count >= 50 { self.cache.removeAll() }
                self.cache[key] = result
            }
            withAnimation(Self.resize) { self.state = result }
        }
    }

    func sync(_ position: Double) {
        guard case .loaded(let lines, synced: true) = state else { return }
        let at = position + lead + offset
        let next = lines.lastIndex { $0.time <= at }
        let singing = next.map { at <= lines[$0].end } ?? true
        guard next != index || singing != isSinging else { return }
        withAnimation(Self.resize) {
            index = next
            isSinging = singing
        }
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
        let legacyKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("lyrics_offset_") }
        guard !legacyKeys.isEmpty else { return }
        for k in legacyKeys { defaults.removeObject(forKey: k) }
    }
}

enum DeviceLatencyStore {
    private static let key = "niche_device_latency_store"

    static func load(for deviceKey: String) -> Double? {
        let store = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        return store?[deviceKey]
    }

    static func save(_ latency: Double, for deviceKey: String) {
        guard !deviceKey.isEmpty else { return }
        var store = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        store[deviceKey] = latency
        UserDefaults.standard.set(store, forKey: key)
    }
}
