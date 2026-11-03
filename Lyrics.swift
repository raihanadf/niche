import AppKit
import SwiftUI

@MainActor
@Observable
final class Lyrics {
    enum State: Equatable { case idle, loading, loaded([LyricLine], synced: Bool), missing }

    private(set) var state = State.idle
    private(set) var index: Int?
    private(set) var isSinging = true
    var autoOffset: Double = 0
    var onLoaded: (([LyricLine], Bool) -> Void)?
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var measured = (text: "", width: CGFloat(0))

    static let lead = 0.42
    private static let resize = Animation.spring(response: 0.45, dampingFraction: 0.95)
    static let closedFont = NSFont(descriptor: NSFont.systemFont(ofSize: 11.5, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 11.5)!

    var line: String {
        guard case .loaded(let lines, let synced) = state else { return "" }
        guard synced else { return lines[0].text }
        guard let index, isSinging, !lines[index].text.isEmpty else { return "♪" }
        return lines[index].text
    }

    var activeLine: LyricLine? {
        guard case .loaded(let lines, let synced) = state, synced else { return nil }
        guard let index, isSinging, index < lines.count, !lines[index].text.isEmpty else { return nil }
        return lines[index]
    }

    var lineWidth: CGFloat {
        let text = line
        if text != measured.text {
            measured = (text, ceil((text as NSString).size(withAttributes: [.font: Self.closedFont]).width))
        }
        return measured.width
    }

    func load(_ track: Track?) {
        guard let track else {
            task?.cancel()
            key = ""
            autoOffset = 0
            withAnimation(Self.resize) {
                state = .idle
                index = nil
            }
            return
        }
        let key = "\(track.artist)|\(track.title)".lowercased()
        guard key != self.key else { return }
        self.key = key
        task?.cancel()
        autoOffset = LyricsAutoSyncStorage.loadOffset(artist: track.artist, title: track.title) ?? 0
        withAnimation(Self.resize) {
            index = nil
            if let cached = cache[key] {
                state = cached
                if case .loaded(let lines, let synced) = cached { onLoaded?(lines, synced) }
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
                if case .loaded(let lines, let synced) = result { self.onLoaded?(lines, synced) }
            }
            withAnimation(Self.resize) { self.state = result }
        }
    }

    func sync(_ position: Double) {
        guard case .loaded(let lines, synced: true) = state else { return }
        let at = position + Self.lead + autoOffset
        let next = lines.lastIndex { $0.time <= at }
        let singing = next.map { at <= lines[$0].end } ?? true
        guard next != index || singing != isSinging else { return }
        withAnimation(Self.resize) {
            index = next
            isSinging = singing
        }
    }
}
