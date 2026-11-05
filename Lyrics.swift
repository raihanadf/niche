import AppKit
import SwiftUI

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let end: Double
    let text: String
}

@MainActor
@Observable
final class Lyrics {
    enum State: Equatable { case idle, loading, loaded([LyricLine], synced: Bool), missing }

    private(set) var state = State.idle
    private(set) var index: Int?
    private(set) var isSinging = true
    @ObservationIgnored private var key = ""
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var measured = (text: "", width: CGFloat(0))

    static let lead = 0.5
    static let closedFont = NSFont(descriptor: NSFont.systemFont(ofSize: 11.5, weight: .semibold).fontDescriptor.withDesign(.rounded)!, size: 11.5)!

    var line: String {
        guard case .loaded(let lines, let synced) = state else { return "" }
        guard synced else { return lines[0].text }
        guard let index, isSinging, !lines[index].text.isEmpty else { return "♪" }
        return lines[index].text
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
            withAnimation(.settle) {
                state = .idle
                index = nil
            }
            return
        }
        let key = "\(track.artist)|\(track.title)".lowercased()
        guard key != self.key else { return }
        self.key = key
        task?.cancel()
        withAnimation(.settle) {
            index = nil
            if let cached = cache[key] { state = cached } else { state = .loading }
        }
        guard state == .loading else { return }
        task = Task { [weak self] in
            let result = await LRCLIB.fetch(title: track.title, artist: track.artist, duration: track.duration)
            guard !Task.isCancelled, let self, self.key == key else { return }
            if case .loaded = result {
                if self.cache.count >= 50 { self.cache.removeAll() }
                self.cache[key] = result
            }
            withAnimation(.settle) { self.state = result }
        }
    }

    func sync(_ position: Double) {
        guard case .loaded(let lines, synced: true) = state else { return }
        let at = position + Self.lead
        let next = lines.lastIndex { $0.time <= at }
        let singing = next.map { at <= lines[$0].end } ?? true
        guard next != index || singing != isSinging else { return }
        withAnimation(.settle) {
            index = next
            isSinging = singing
        }
    }
}

private enum LRCLIB {
    private static let agent = "Niche/\(Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String) (https://github.com/raihanadf/niche)"
    private static let noise = try! NSRegularExpression(
        pattern: #"\s*[(\[](official( music| lyric)? video|official audio|audio|lyrics?( video)?|visuali[sz]er|mv|4k|hd|live[^)\]]*|f(ea)?t\.[^)\]]*|prod\.[^)\]]*)[)\]]"#,
        options: .caseInsensitive)
    private static let version = try! NSRegularExpression(
        pattern: #"\s*[(\[][^)\]]*(remix|edit|version|live|acoustic|sped up|slowed)[^)\]]*[)\]]"#,
        options: .caseInsensitive)

    static func fetch(title: String, artist: String, duration: Double) async -> Lyrics.State {
        var artist = artist
        for suffix in [" - Topic", "VEVO"] where artist.hasSuffix(suffix) { artist = String(artist.dropLast(suffix.count)) }
        artist = artist.trimmingCharacters(in: .whitespaces)
        var title = strip(noise, from: title)
        let parts = title.components(separatedBy: " - ")
        let isChannel = ["kexp", "vevo", "records", "channel", "music", "tv"].contains { artist.lowercased().contains($0) }
        if parts.count > 1, artist.isEmpty || isChannel || artist.caseInsensitiveCompare(parts[0]) == .orderedSame {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }
        var titles = [title]
        let base = strip(version, from: title.components(separatedBy: " - ")[0])
        if !base.isEmpty, base != title { titles.append(base) }
        var artists = [artist]
        let lead = artist.split(separator: #/\s*(,|&|\sx\s|\sfeat\.?\s|\sft\.\s|\swith\s)\s*/#.ignoresCase(), maxSplits: 1).first.map(String.init)
        if let lead, lead != artist { artists.append(lead) }

        for (name, artist) in titles.flatMap({ name in artists.map { (name, $0) } }) {
            var query = ["track_name": name, "artist_name": artist]
            if duration > 1 { query["duration"] = String(Int(duration)) }
            if let item = await json("get", query) as? [String: Any], let found = parse(item) { return found }
            let results = await json("search", ["q": artist.isEmpty ? name : "\(artist) \(name)"]) as? [[String: Any]]
            let best = results?.compactMap { item in
                score(item, title: name, artist: artist, duration: duration).flatMap { score in parse(item).map { ($0, score) } }
            }
            .max { $0.1 < $1.1 }
            if let best { return best.0 }
        }
        return .missing
    }

    private static func strip(_ regex: NSRegularExpression, from text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
    }

    private static func json(_ path: String, _ query: [String: String]) async -> Any? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 5)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as! HTTPURLResponse).statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            NSLog("Niche could not reach lrclib: %@", String(describing: error))
            return nil
        }
    }

    private static func score(_ item: [String: Any], title: String, artist: String, duration: Double) -> Int? {
        var score = (item["syncedLyrics"] as? String)?.isEmpty == false ? 1000 : 0
        if duration > 0, let length = item["duration"] as? Double {
            guard abs(length - duration) <= 10 else { return nil }
            score -= Int(abs(length - duration) * 50)
        }
        for (field, want) in [("trackName", title.lowercased()), ("artistName", artist.lowercased())] {
            guard let have = (item[field] as? String)?.lowercased(), !have.isEmpty, !want.isEmpty else { continue }
            score += have == want ? 500 : have.contains(want) || want.contains(have) ? 250 : 0
        }
        return score
    }

    private static func parse(_ item: [String: Any]) -> Lyrics.State? {
        if let synced = item["syncedLyrics"] as? String {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .loaded(lines, synced: true) }
        }
        if let plain = item["plainLyrics"] as? String {
            let lines = plain.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !lines.isEmpty { return .loaded(lines.enumerated().map { LyricLine(id: $0, time: 0, end: 0, text: $1) }, synced: false) }
        }
        return nil
    }

    private static func parseLRC(_ lrc: String) -> [LyricLine] {
        var stamps: [(time: Double, text: String)] = []
        var offset = 0.0
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = raw.drop { $0.isWhitespace }
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close].split(separator: ":")
                let numbers = tag.compactMap { Double($0) }
                if tag.count == 2, tag[0].lowercased() == "offset", let ms = Double(tag[1]) { offset = ms / 1000 }
                if numbers.count == tag.count, (2...3).contains(tag.count) {
                    times.append(numbers[0] * 60 + numbers[1] + (tag.count == 3 ? numbers[2] / 100 : 0))
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.replacing(#/<\d+:\d+([.:]\d+)?>/#, with: "").trimmingCharacters(in: .whitespaces)
            stamps += times.map { ($0, text) }
        }
        stamps = stamps.map { (max(0, $0.time - offset), $0.text) }
        stamps.sort { $0.time < $1.time }
        return stamps.indices.map { i in
            let (time, text) = stamps[i]
            let next = i + 1 < stamps.count ? stamps[i + 1].time : time + 6
            let sung = max(2, Double(text.split(separator: " ").count) * 0.45 + 1.2)
            return LyricLine(id: i, time: time, end: max(next - time > sung + 2 ? time + sung : next, time + 1), text: text)
        }
    }
}

struct LyricsView: View {
    let player: MusicPlayer
    let track: Track
    static let height: CGFloat = 140
    private static let mask = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                                     .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom)

    var body: some View {
        Group {
            switch player.lyrics.state {
            case .idle, .loading:
                LyricsSkeleton()
            case .missing:
                Text("No lyrics for this song")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let lines, let synced):
                let active = synced ? player.lyrics.index ?? 0 : min(Int(player.position / max(track.duration, 1) * Double(lines.count)), lines.count - 1)
                rows(lines, active: active, synced: synced)
                    .offset(y: Self.height * 0.38 - 19 - CGFloat(active) * 44)
                    .animation(.arrive, value: active)
                    .frame(height: Self.height, alignment: .top)
            }
        }
        .transition(.blurReplace)
        .animation(.fadeIn, value: player.lyrics.state)
        .frame(height: Self.height)
        .clipped()
        .mask(Self.mask)
    }

    private func rows(_ lines: [LyricLine], active: Int, synced: Bool) -> some View {
        let start = max(0, active - 4)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(lines[start...min(lines.count - 1, active + 4)]) { line in
                LyricRow(text: line.text.isEmpty ? "♪" : line.text,
                         isActive: synced && line.id == active && player.lyrics.isSinging,
                         distance: synced ? min(abs(line.id - active), 4) : 0) {
                    guard synced, track.duration > 0 else { return }
                    player.seek(to: line.time / track.duration)
                }
            }
        }
        .padding(.top, CGFloat(start) * 44)
    }
}

private struct LyricsSkeleton: View {
    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bar(width: 135, height: 13, opacity: isOn ? 0.14 : 0.05)
            bar(width: 185, height: 16, opacity: isOn ? 0.32 : 0.14)
            bar(width: 115, height: 13, opacity: isOn ? 0.14 : 0.05)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { isOn = true } }
    }

    private func bar(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: width, height: height)
    }
}

private struct LyricRow: View {
    let text: String
    let isActive: Bool
    let distance: Int
    let seek: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: seek) {
            Text(text)
                .font(.system(size: isActive ? 14.5 : 13, weight: isActive ? .bold : .medium, design: .rounded))
                .foregroundStyle(.white.opacity(opacity))
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 38)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(isHovered && !isActive ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.arrive, value: isActive)
        .animation(.arrive, value: distance)
        .onHover { inside in withAnimation(.hover) { isHovered = inside } }
    }

    private var opacity: Double {
        if isActive { return 1 }
        if isHovered { return 0.85 }
        return [0.55, 0.42, 0.2, 0.08][min(distance, 3)]
    }
}
