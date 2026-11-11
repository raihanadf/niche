import AppKit
import CoreImage
import ImageIO
import QuartzCore
import SwiftUI

struct Track: Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artwork: NSImage?
    let artworkKey: String

    func isSameSong(as other: Track) -> Bool {
        title == other.title && artist == other.artist && album == other.album
    }

    static func == (a: Track, b: Track) -> Bool { a.isSameSong(as: b) && a.artworkKey == b.artworkKey }
}

@MainActor
@Observable
final class MusicPlayer {
    private(set) var track: Track? {
        didSet { followLyrics() }
    }
    private(set) var isPlaying = false {
        didSet { followLyrics() }
    }
    private(set) var isShuffled = false
    private(set) var position: Double = 0
    private(set) var songChangeToken = 0
    var currentPosition: Double {
        guard let track, isPlaying else { return position }
        let live = (CACurrentMediaTime() - baseMonotonic) * rate
        let raw = max(elapsedAtTimestamp + live, 0)
        return track.duration > 0 ? min(raw, track.duration) : raw
    }
    var allowsAnyApp: Bool {
        didSet {
            UserDefaults.standard.set(allowsAnyApp, forKey: "musicAnyApp")
            if let lastSnapshot { apply(lastSnapshot) }
        }
    }
    let spectrum = AudioSpectrum()
    let output = OutputDevice()
    let lyrics = Lyrics()
    var allowsLyrics: Bool {
        didSet {
            UserDefaults.standard.set(allowsLyrics, forKey: "musicLyrics")
            if !allowsLyrics { isShowingLyrics = false }
            followLyrics()
        }
    }
    var isShowingLyrics = false {
        didSet {
            UserDefaults.standard.set(isShowingLyrics, forKey: "musicShowingLyrics")
            followLyrics()
        }
    }

    @ObservationIgnored private var elapsedAtTimestamp: Double = 0
    @ObservationIgnored private var baseMonotonic: Double = CACurrentMediaTime()
    @ObservationIgnored private var rate: Double = 1
    @ObservationIgnored private var lyricsTimer: Timer?
    @ObservationIgnored private var pendingSong: Track?
    @ObservationIgnored private var lastSong: Track?
    @ObservationIgnored private var pendingDeadline: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: NowPlayingSnapshot?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private let send: @convention(c) (Int, AnyObject?) -> Bool
    @ObservationIgnored private let setElapsed: @convention(c) (Double) -> Void
    @ObservationIgnored private let setShuffle: @convention(c) (Int) -> Void

    private static let musicApps: Set<String> = ["com.apple.Music", "com.spotify.client"]

    init() {
        UserDefaults.standard.register(defaults: ["musicAnyApp": false, "musicLyrics": true, "musicShowingLyrics": true])
        allowsAnyApp = UserDefaults.standard.bool(forKey: "musicAnyApp")
        let lyricsAllowed = UserDefaults.standard.bool(forKey: "musicLyrics")
        allowsLyrics = lyricsAllowed
        isShowingLyrics = lyricsAllowed && UserDefaults.standard.bool(forKey: "musicShowingLyrics")
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let send = dlsym(handle, "MRMediaRemoteSendCommand"),
              let setElapsed = dlsym(handle, "MRMediaRemoteSetElapsedTime"),
              let setShuffle = dlsym(handle, "MRMediaRemoteSetShuffleMode") else {
            fatalError("MediaRemote.framework symbols not found")
        }
        self.send = unsafeBitCast(send, to: (@convention(c) (Int, AnyObject?) -> Bool).self)
        self.setElapsed = unsafeBitCast(setElapsed, to: (@convention(c) (Double) -> Void).self)
        self.setShuffle = unsafeBitCast(setShuffle, to: (@convention(c) (Int) -> Void).self)
        output.onDeviceChange = { [weak self] in
            guard let self else { return }
            self.spectrum.refresh()
            self.lyrics.updateTransport(self.output.transportType)
        }
        lyrics.updateTransport(output.transportType)
        lyrics.positionProvider = { [weak self] in self?.currentPosition ?? 0 }
    }

    func start() {
        guard let resources = Bundle.main.resourceURL else { fatalError("app bundle has no resources") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.appendingPathComponent("mediaremote-adapter.pl").path,
                             resources.appendingPathComponent("MediaRemoteAdapter.framework").path,
                             "stream", "--no-diff", "--debounce=50", "--micros"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        readLines(from: pipe.fileHandleForReading, label: "niche.nowplaying") { [weak self] line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { return }
            let snapshot = NowPlayingSnapshot(payload)
            Task { @MainActor in self?.apply(snapshot) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.start()
            }
        }
        do { try process.run() } catch { fatalError("could not launch mediaremote-adapter: \(error)") }
        self.process = process
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        spectrum.stop()
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        lastSnapshot = snapshot
        guard let next = snapshot.track, allowsAnyApp || snapshot.app.map(Self.musicApps.contains) == true else {
            guard track != nil, clearTask == nil else { return }
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                self.clearTask = nil
                self.pendingSong = nil
                self.pendingDeadline?.cancel()
                self.track = nil
                self.isPlaying = false
                self.spectrum.follow(pid: nil)
            }
            return
        }
        clearTask?.cancel()
        clearTask = nil
        let isNewSong = lastSong.map { !$0.isSameSong(as: next) } ?? false
        if isNewSong {
            lyrics.updateTransport(output.transportType)
        }
        if isPlaying && !snapshot.isPlaying && !isNewSong {
            let live = (CACurrentMediaTime() - baseMonotonic) * rate
            elapsedAtTimestamp = max(snapshot.elapsed, min(elapsedAtTimestamp + live, next.duration))
            baseMonotonic = CACurrentMediaTime()
        } else if snapshot.isPlaying {
            let age = max(0, Date().timeIntervalSince(snapshot.timestamp))
            let effectiveRate = snapshot.rate > 0 ? snapshot.rate : 1.0
            let extrapolated = snapshot.elapsed + age * effectiveRate
            elapsedAtTimestamp = next.duration > 0 ? min(extrapolated, next.duration) : extrapolated
            baseMonotonic = CACurrentMediaTime()
        } else {
            elapsedAtTimestamp = snapshot.elapsed
            baseMonotonic = CACurrentMediaTime()
        }
        rate = snapshot.rate
        isPlaying = snapshot.isPlaying
        if let shuffle = snapshot.shuffleMode { isShuffled = shuffle != 1 }
        spectrum.follow(pid: snapshot.isPlaying ? snapshot.pid : nil)
        if isNewSong && next.artwork == nil {
            if pendingSong.map({ !$0.isSameSong(as: next) }) ?? true {
                pendingDeadline?.cancel()
                pendingDeadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.8))
                    guard !Task.isCancelled, let self, let held = self.pendingSong else { return }
                    self.commit(held)
                }
            }
            pendingSong = next
            return
        }
        commit(next)
    }

    private func commit(_ next: Track) {
        pendingSong = nil
        pendingDeadline?.cancel()
        if let previous = lastSong, !previous.isSameSong(as: next) {
            songChangeToken += 1
        }
        lastSong = next
        track = next
        tick()
    }

    func tick() {
        guard let track else { return }
        let live = isPlaying ? (CACurrentMediaTime() - baseMonotonic) * rate : 0
        let next = min(max(elapsedAtTimestamp + live, 0), track.duration)
        if next != position { position = next }
        if isShowingLyrics { lyrics.sync(currentPosition) }
    }

    private func followLyrics() {
        lyrics.load(isShowingLyrics ? track : nil)
        let follow = isShowingLyrics && isPlaying
        guard follow != (lyricsTimer != nil) else { return }
        lyricsTimer?.invalidate()
        lyricsTimer = nil
        guard follow else { return }
        let timer = Timer(timeInterval: 0.033, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowingLyrics else { return }
                self.lyrics.sync(self.currentPosition)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lyricsTimer = timer
    }

    func togglePlay() { _ = send(2, nil) }
    func skip(forward: Bool) { _ = send(forward ? 4 : 5, nil) }

    func seek(to fraction: Double) {
        guard let track else { return }
        let target = track.duration * min(max(fraction, 0), 1)
        setElapsed(target)
        elapsedAtTimestamp = target
        baseMonotonic = CACurrentMediaTime()
        tick()
    }

    func toggleShuffle() {
        setShuffle(isShuffled ? 1 : 3)
        isShuffled.toggle()
    }
}

func readLines(from handle: FileHandle, label: String, line: @escaping @Sendable (Data) -> Void) {
    DispatchQueue(label: label, qos: .utility).async {
        var buffer = Data()
        while true {
            let isOpen = autoreleasepool { () -> Bool in
                let chunk = handle.availableData
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 0x0A) {
                    let next = Data(buffer[buffer.startIndex..<end])
                    buffer.removeSubrange(buffer.startIndex...end)
                    line(next)
                }
                return !chunk.isEmpty
            }
            if !isOpen { return }
        }
    }
}

private struct NowPlayingSnapshot: @unchecked Sendable {
    let track: Track?
    let isPlaying: Bool
    let elapsed: Double
    let timestamp: Date
    let rate: Double
    let shuffleMode: Int?
    let pid: pid_t?
    let app: String?

    nonisolated(unsafe) private static var cachedArtwork: (key: String, image: NSImage?) = ("", nil)

    init(_ p: [String: Any]) {
        if let title = p["title"] as? String, !title.isEmpty {
            let art = p["artworkData"] as? String
            let key = art.map { "\($0.count):\($0.suffix(32))" } ?? ""
            if key != Self.cachedArtwork.key {
                Self.cachedArtwork = (key, art.flatMap { Data(base64Encoded: $0) }.flatMap(Self.thumbnail))
            }
            track = Track(title: title,
                          artist: p["artist"] as? String ?? "",
                          album: p["album"] as? String ?? "",
                          duration: (p["durationMicros"] as? Double ?? 0) / 1_000_000,
                          artwork: Self.cachedArtwork.image,
                          artworkKey: key)
        } else {
            track = nil
        }
        isPlaying = p["playing"] as? Bool ?? false
        elapsed = (p["elapsedTimeMicros"] as? Double ?? 0) / 1_000_000
        timestamp = (p["timestampEpochMicros"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        rate = p["playbackRate"] as? Double ?? 1
        shuffleMode = p["shuffleMode"] as? Int
        pid = (p["processIdentifier"] as? Int).map { pid_t($0) }
        app = p["parentApplicationBundleIdentifier"] as? String ?? p["bundleIdentifier"] as? String
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128 * max(width, height) / max(min(width, height), 1),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct ArtworkTile: View {
    let track: Track

    var body: some View {
        if let artwork = track.artwork {
            Color.clear.overlay {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        } else {
            Color(white: 0.22).overlay {
                Image(systemName: "music.note").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

struct ArtworkSwap: ViewModifier, Animatable {
    var progress: Double
    let incoming: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        content
            .scaleEffect(x: incoming ? 0.06 + 0.94 * p : 1 - 0.94 * p, y: 1)
            .blur(radius: incoming ? 7 * max(0, 1 - p).squareRoot() : 0)
    }
}

struct ArtworkView: View {
    let track: Track
    let token: Int
    let isPlaying: Bool
    let cornerRadius: CGFloat

    @State private var current: Track?
    @State private var outgoing: Track?
    @State private var incomingProgress = 1.0
    @State private var outgoingProgress = 0.0

    var body: some View {
        ZStack {
            if let outgoing {
                ArtworkTile(track: outgoing).clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .modifier(ArtworkSwap(progress: outgoingProgress, incoming: false))
            }
            ArtworkTile(track: current ?? track).clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .modifier(ArtworkSwap(progress: incomingProgress, incoming: true))
                .opacity(outgoing == nil ? 1 : 0)
        }
        .scaleEffect(isPlaying ? 1 : 0.82)
        .animation(.grow, value: isPlaying)
        .onAppear { current = track }
        .onChange(of: track) {
            guard let current, current.isSameSong(as: track), outgoing == nil else { return }
            withAnimation(.leave) { self.current = track }
        }
        .onChange(of: token) {
            outgoing = current
            current = track
            outgoingProgress = 0
            incomingProgress = 0
            withAnimation(.easeIn(duration: 0.1)) {
                outgoingProgress = 1
            } completion: {
                outgoing = nil
                withAnimation(.spring(Spring(duration: 0.4, bounce: 0.1), blendDuration: 0)) {
                    incomingProgress = 1
                }
            }
        }
    }
}

struct WaveformView: View {
    let track: Track
    let spectrum: AudioSpectrum
    let isPlaying: Bool
    let barWidth: CGFloat
    let maxHeight: CGFloat

    static let tick = 0.28

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let isLive = spectrum.isEnabled
        ArtworkTile(track: track)
            .blur(radius: 5)
            .saturation(1.5)
            .brightness(0.12)
            .mask {
                TimelineView(.animation(minimumInterval: Self.tick, paused: isLive || !isPlaying)) { context in
                    let levels = spectrum.levels
                    let step = UInt64(context.date.timeIntervalSinceReferenceDate / Self.tick)
                    let minHeight: CGFloat = 2.5
                    let heights = levels.indices.map { bar -> CGFloat in
                        let level = isLive ? levels[bar] : Self.simulatedLevel(track: track, bar: bar, step: step)
                        let raw = isPlaying ? minHeight + CGFloat(level) * (maxHeight - minHeight) : minHeight
                        return (raw * displayScale).rounded() / displayScale
                    }
                    HStack(alignment: .center, spacing: barWidth * 0.75) {
                        ForEach(heights.indices, id: \.self) { bar in
                            Capsule().frame(width: barWidth, height: heights[bar])
                        }
                    }
                    .animation(isLive ? .easeOut(duration: 1.0 / 24) : .spring(duration: Self.tick), value: heights)
                    .animation(.easeOut(duration: 0.3), value: isPlaying)
                }
            }
            .frame(width: CGFloat(AudioSpectrum.bands) * barWidth * 1.75, height: maxHeight)
    }

    static func simulatedLevel(track: Track, bar: Int, step: UInt64) -> Float {
        let seed = UInt64(bitPattern: Int64(track.title.hashValue ^ track.artist.hashValue))
        var x = (step &* 0xbf58476d1ce4e5b9) ^ (UInt64(bar) &* 0x94d049bb133111eb) ^ seed
        x = x &+ 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        x ^= x >> 31
        return 0.25 + 0.75 * Float(x % 1000) / 1000
    }
}

struct ClosedWaveform: NSViewRepresentable {
    let track: Track
    let spectrum: AudioSpectrum
    let isPlaying: Bool

    func makeNSView(context: Context) -> WaveformLayer { WaveformLayer() }

    func updateNSView(_ view: WaveformLayer, context: Context) {
        view.update(track: track, levels: spectrum.isEnabled ? spectrum.levels : nil, isPlaying: isPlaying)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveformLayer, context: Context) -> CGSize? {
        CGSize(width: CGFloat(AudioSpectrum.bands) * WaveformLayer.barWidth * 1.75, height: WaveformLayer.maxHeight)
    }
}

final class WaveformLayer: NSView {
    static let barWidth: CGFloat = 2.4
    static let maxHeight: CGFloat = 12
    private let art = CALayer()
    private let bars = CALayer()
    private var track: Track?
    private var levels: [Float]?
    private var isPlaying = false
    private var timer: Timer?
    private var step: UInt64 = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        art.contentsGravity = .resizeAspectFill
        art.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])!,
                       CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 1.5, kCIInputBrightnessKey: 0.12])!]
        for _ in 0..<AudioSpectrum.bands {
            let bar = CALayer()
            bar.backgroundColor = .white
            bar.cornerRadius = Self.barWidth / 2
            bars.addSublayer(bar)
        }
        art.mask = bars
        layer!.addSublayer(art)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(track: Track, levels: [Float]?, isPlaying: Bool) {
        if track.artworkKey != self.track?.artworkKey {
            art.contents = track.artwork
            art.backgroundColor = track.artwork == nil ? NSColor(white: 0.22, alpha: 1).cgColor : nil
        }
        self.track = track
        self.levels = levels
        self.isPlaying = isPlaying
        let runs = isPlaying && levels == nil && window != nil
        if runs != (timer != nil) {
            timer?.invalidate()
            timer = nil
            if runs {
                let timer = Timer(timeInterval: WaveformView.tick, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.step += 1
                        self.layoutBars(duration: WaveformView.tick)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
        }
        layoutBars(duration: levels == nil ? 0.3 : 1.0 / 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let track { update(track: track, levels: levels, isPlaying: isPlaying) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        art.contentsScale = window.backingScaleFactor
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = bounds
        bars.frame = bounds
        CATransaction.commit()
        layoutBars(duration: 0)
    }

    private func layoutBars(duration: Double) {
        guard let track, let window, let layers = bars.sublayers else { return }
        let scale = window.backingScaleFactor
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setDisableActions(duration == 0)
        for (bar, layer) in layers.enumerated() {
            let level = levels.map { $0[bar] } ?? WaveformView.simulatedLevel(track: track, bar: bar, step: step)
            let raw = isPlaying ? 2.5 + CGFloat(level) * (Self.maxHeight - 2.5) : 2.5
            let height = (raw * scale).rounded() / scale
            layer.frame = CGRect(x: (CGFloat(bar) * 1.75 + 0.375) * Self.barWidth, y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
        }
        CATransaction.commit()
    }
}

struct MarqueeText: View {
    let text: String
    let font: Font
    let width: CGFloat

    @State private var textWidth: CGFloat = 0

    var body: some View {
        let gap: CGFloat = 28
        let hold = 1.5
        let speed: CGFloat = 28
        let travel = textWidth + gap
        let cycle = Double(travel / speed) + hold
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: textWidth <= width)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: max(cycle, 0.001))
            let offset = textWidth > width ? -CGFloat(max(0, t - hold)) * speed : 0
            HStack(spacing: gap) {
                label
                if textWidth > width { label }
            }
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                       .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(textWidth > width ? 1 : 0)
                    .overlay(Color.black.opacity(textWidth > width ? 0 : 1))
            )
        }
    }

    private var label: some View {
        Text(text).font(font).fixedSize()
            .background(GeometryReader { proxy in
                Color.clear.onAppear { textWidth = proxy.size.width }
                    .onChange(of: text) { textWidth = proxy.size.width }
            })
    }
}

struct ProgressBar: View {
    let track: Track
    let fraction: Double
    let isSeeking: Bool
    let songToken: Int
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                ArtworkTile(track: track)
                    .blur(radius: 6)
                    .saturation(1.6)
                    .brightness(0.15)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .mask(alignment: .leading) {
                        Capsule()
                            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                            .animation(.spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0), value: songToken)
                            .animation(isSeeking ? .spring(response: 0.3, dampingFraction: 1.0, blendDuration: 0) : .linear(duration: 1),
                                       value: fraction)
                    }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in onSeek(location.x / proxy.size.width) }
        }
        .frame(height: 6)
    }
}

struct VolumeSlider: View {
    let level: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(.white.opacity(0.55))
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
                    .animation(.level, value: level)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(drag.location.x / proxy.size.width)
            })
        }
        .frame(height: 6)
    }
}

struct MusicExpandedView: View {
    let player: MusicPlayer
    let width: CGFloat
    @State private var isSeeking = false
    @State private var skips = (back: 0, forward: 0)

    var body: some View {
        if let track = player.track {
            playing(track)
        } else {
            Text("Nothing playing").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .frame(width: width, height: 120)
        }
    }

    private func playing(_ track: Track) -> some View {
        HStack(alignment: .top, spacing: 16) {
            controls(track)
            if player.isShowingLyrics {
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: LyricsView.height)
                LyricsView(player: player, track: track)
                    .frame(width: LabState.lyricsWidth - 33)
                    .transition(.blurReplace.combined(with: .offset(x: 14)))
            }
        }
    }

    private func controls(_ track: Track) -> some View {
        let art: CGFloat = 56
        let waveWidth: CGFloat = 4 * 2.5 * 1.75 + (player.allowsLyrics ? 26 : 0)
        let textWidth = width - art - waveWidth - 30
        let output = player.output
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(track: track, token: player.songChangeToken, isPlaying: player.isPlaying, cornerRadius: 12)
                    .frame(width: art, height: art)
                VStack(alignment: .leading, spacing: 1) {
                    ZStack(alignment: .leading) {
                        MarqueeText(text: track.title, font: .system(size: 13.5, weight: .semibold),
                                    width: textWidth)
                            .id(player.songChangeToken)
                            .transition(.blurReplace(.downUp))
                    }
                    .frame(height: 17)
                    ZStack(alignment: .leading) {
                        Text(track.artist).font(.system(size: 13, weight: .regular)).foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .id(player.songChangeToken)
                            .transition(.blurReplace(.downUp))
                    }
                    .frame(height: 16)
                }
                .frame(width: textWidth, alignment: .leading)
                .animation(.arrive, value: player.songChangeToken)
                Spacer(minLength: 0)
                WaveformView(track: track, spectrum: player.spectrum, isPlaying: player.isPlaying, barWidth: 2.5, maxHeight: 14)
                if player.allowsLyrics {
                    Button {
                        withAnimation(.arrive) { player.isShowingLyrics.toggle() }
                    } label: {
                        Image(systemName: player.isShowingLyrics ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 13, weight: .medium))
                            .opacity(player.isShowingLyrics ? 1 : 0.5)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -14)
                }
            }
            .frame(height: art)
            .padding(.bottom, 13)
            HStack(spacing: 10) {
                timeLabel(player.position)
                ProgressBar(track: track, fraction: player.position / track.duration, isSeeking: isSeeking, songToken: player.songChangeToken) { fraction in
                    isSeeking = true
                    player.seek(to: fraction)
                    Task { try? await Task.sleep(for: .seconds(0.35)); isSeeking = false }
                }
                timeLabel(track.duration - player.position, negative: true)
            }
            .frame(height: 12)
            .padding(.bottom, 20)
            HStack(spacing: 0) {
                ControlButton(action: { player.toggleShuffle() }) { ShuffleGlyph(isOn: player.isShuffled) }
                ControlButton(action: { skips.back += 1; player.skip(forward: false) }) {
                    SkipGlyph(forward: false, trigger: skips.back)
                }
                ControlButton(action: { player.togglePlay() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 27, weight: .medium))
                        .contentTransition(.symbolEffect(.replace.downUp.wholeSymbol))
                        .animation(.glyph, value: player.isPlaying)
                }
                ControlButton(action: { skips.forward += 1; player.skip(forward: true) }) {
                    SkipGlyph(forward: true, trigger: skips.forward)
                }
                ControlButton(isActive: output.isShowingVolume, action: {
                    withAnimation(.arrive) { output.isShowingVolume.toggle() }
                }) {
                    Image(systemName: output.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .opacity(output.isShowingVolume ? 1 : 0.5)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.glyph, value: output.symbol)
                }
                .disabled(!output.canSetVolume)
            }
            .frame(height: 30)
            .padding(.horizontal, -10)
            if output.isShowingVolume {
                HStack(spacing: 10) {
                    Button { output.toggleMute() } label: {
                        Image(systemName: output.isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    VolumeSlider(level: output.isMuted ? 0 : output.volume) { output.setVolume($0) }
                    Image(systemName: "speaker.wave.2.fill").frame(width: 20)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 12)
                .padding(.horizontal, 10)
                .padding(.top, 20)
                .transition(.blurReplace.combined(with: .offset(y: -8)))
            }
        }
        .frame(width: width)
        .foregroundStyle(.white)
    }

    private func timeLabel(_ seconds: Double, negative: Bool = false) -> some View {
        let s = Int(max(seconds, 0))
        return Text("\(negative ? "-" : "")\(s / 60):\(String(format: "%02d", s % 60))")
            .font(.system(size: 10.5, weight: .medium)).kerning(0.1)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 32, alignment: negative ? .trailing : .leading)
    }
}

private struct ControlButton<Label: View>: View {
    var isActive = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: 46, height: 42)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.white.opacity(isActive ? 0.13 : isHovered ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressSquash())
        .onHover { inside in withAnimation(.hover) { isHovered = inside } }
        .frame(maxWidth: .infinity)
    }
}

private struct ShuffleGlyph: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Image(systemName: "shuffle").font(.system(size: 17, weight: .medium))
                .offset(y: isOn ? -3 : 0)
            Circle().frame(width: 3.5, height: 3.5)
                .scaleEffect(isOn ? 1 : 0.2)
                .opacity(isOn ? 1 : 0)
                .offset(y: 9)
        }
        .opacity(0.5)
        .animation(.glyph, value: isOn)
    }
}

private struct SkipGlyph: View {
    let forward: Bool
    let trigger: Int

    var body: some View {
        let w: CGFloat = 12.5
        KeyframeAnimator(initialValue: 0.0, trigger: trigger) { p in
            ZStack {
                triangle.offset(x: w / 2).scaleEffect(max(0, 1 - 2 * p), anchor: .trailing).opacity(max(0, 1 - 2 * p))
                triangle.offset(x: -w / 2 + w * min(1, 2 * p))
                triangle.offset(x: -w / 2).scaleEffect(min(1, max(0, (p - 0.25) / 0.75)))
                    .opacity(min(1, max(0, (p - 0.25) / 0.5)))
            }
            .scaleEffect(x: forward ? 1 : -1)
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.38)
        }
    }

    private var triangle: some View {
        Image(systemName: "play.fill").font(.system(size: 15, weight: .medium))
    }
}

private struct PressSquash: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.press, value: configuration.isPressed)
    }
}

struct MusicClosedView: View {
    let player: MusicPlayer
    let lab: LabState
    static let slot: CGFloat = 38
    @State private var lastTrack: Track?

    var body: some View {
        let shown = player.track ?? lastTrack
        let line = player.isShowingLyrics ? player.lyrics.line : ""
        let underNotch = lab.usesLyricsShelf && !line.isEmpty

        VStack(spacing: 0) {
            if let track = shown {
                HStack(spacing: 0) {
                    ArtworkView(track: track, token: player.songChangeToken, isPlaying: player.isPlaying, cornerRadius: LabState.closedArtRadius)
                        .frame(width: LabState.closedArtSize, height: LabState.closedArtSize)
                        .offset(y: LabState.closedArtOffset)
                        .padding(.leading, LabState.closedArtLeading)
                        .frame(width: Self.slot, alignment: .leading)
                    if line.isEmpty || underNotch {
                        Spacer(minLength: 0)
                    } else {
                        lyric(line)
                            .padding(.horizontal, ClosedLyricsLayout.islandHorizontalPadding)
                    }
                    ClosedWaveform(track: track, spectrum: player.spectrum, isPlaying: player.isPlaying)
                        .padding(.trailing, 9)
                        .frame(width: Self.slot, alignment: .trailing)
                }
                .frame(height: LabState.hardwareNotch.height + (lab.usesLyricsShelf ? 0 : lab.closedLyricsHeight))

                if underNotch {
                    lyric(line)
                        .padding(.horizontal, ClosedLyricsLayout.shelfHorizontalPadding)
                        .frame(height: lab.closedLyricsHeight)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .onAppear { lastTrack = player.track }
        .onChange(of: player.track) { _, track in
            if let track { lastTrack = track }
        }
    }

    private func lyric(_ line: String) -> some View {
        let primaryID = "\(player.lyrics.activeLine?.id ?? -1):\(line)"
        let frameHeight = ClosedLyricsLayout.lyricFrameHeight(for: lab.closedLyricsMetrics)
        return ZStack {
            ClosedKaraokeLyricsView(
                player: player,
                line: line,
                activeLine: player.lyrics.activeLine
            )
            .id(primaryID)
            .transition(.blurReplace(.downUp))
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.90), value: primaryID)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: frameHeight)
        .clipped()
        .animation(.spring(response: 0.45, dampingFraction: 0.95), value: frameHeight)
    }
}
