import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

@MainActor
@Observable
final class AudioSpectrum {
    nonisolated static let bands = 4
    private(set) var levels = [Float](repeating: 0, count: bands)

    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var requestedPID: pid_t = 0
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            updateActiveState()
        }
    }
    @ObservationIgnored var isVocalSyncActive = false {
        didSet {
            guard isVocalSyncActive != oldValue else { return }
            updateActiveState()
        }
    }
    @ObservationIgnored nonisolated(unsafe) var onVocalSample: (@Sendable (Float) -> Void)?
    private var isTapActive: Bool { isEnabled || isVocalSyncActive }
    private func updateActiveState() {
        let wanted = requestedPID
        stop()
        if isTapActive { follow(pid: wanted) }
    }
    @ObservationIgnored private let session = TapSession()

    func follow(pid: pid_t?) {
        requestedPID = pid ?? 0
        let target = isTapActive ? requestedPID : 0
        guard target != self.pid else { return }
        self.pid = target
        levels = [Float](repeating: 0, count: Self.bands)
        session.queue.async { [session, weak self] in
            session.stop()
            guard target > 0 else { return }
            do {
                try session.start(pid: target, onLevels: { [weak self] levels in
                    Task { @MainActor in
                        guard let self, self.pid == target, self.isEnabled, zip(self.levels, levels).contains(where: { abs($0 - $1) >= 0.008 }) else { return }
                        self.levels = levels
                    }
                }, onVocal: { [weak self] sample in
                    self?.onVocalSample?(sample)
                })
            } catch {
                NSLog("Niche audio tap failed for pid %d: %@", target, String(describing: error))
                session.stop()
            }
        }
    }

    func refresh() {
        guard requestedPID > 0 else { return }
        pid = 0
        follow(pid: requestedPID)
    }

    func stop() {
        pid = 0
        levels = [Float](repeating: 0, count: Self.bands)
        session.queue.async { [session] in session.stop() }
    }
}

private final class TapSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "niche.tap")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ioQueue: DispatchQueue?

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            ioQueue?.sync {}
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioQueue = nil
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    func start(pid: pid_t, onLevels: @escaping @Sendable ([Float]) -> Void, onVocal: (@Sendable (Float) -> Void)? = nil) throws {
        let process = try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject,
                                    qualifier: pid, as: AudioObjectID.self)
        guard process != kAudioObjectUnknown else { throw TapError.noAudioProcess }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        let output = try Self.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, as: AudioDeviceID.self)
        let outputUID = try Self.read(output, kAudioDevicePropertyDeviceUID, as: CFString.self) as String
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Niche Spectrum",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "create aggregate device")

        let format = try Self.read(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { throw TapError.notFloat }
        let analyzer = SpectrumAnalyzer(bands: AudioSpectrum.bands, sampleRate: Float(format.mSampleRate))
        let interleavedChannels = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : Int(format.mChannelsPerFrame)
        let ioQueue = DispatchQueue(label: "niche.spectrum", qos: .userInteractive)
        self.ioQueue = ioQueue

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(first.mDataByteSize) / MemoryLayout<Float>.size)
            guard let levels = analyzer.process(samples, channels: interleavedChannels, onVocal: onVocal) else { return }
            onLevels(levels)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "start aggregate device")
    }

    enum TapError: Error { case noAudioProcess, notFloat, status(String, OSStatus) }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.status(what, status) }
    }
    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                qualifier: pid_t? = nil, as: T.Type) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var status: OSStatus
        if var q = qualifier {
            status = AudioObjectGetPropertyData(object, &address, UInt32(MemoryLayout<pid_t>.size), &q, &size, value)
        } else {
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        }
        guard status == noErr else { throw TapError.status("read property \(selector)", status) }
        return value.move()
    }
}

private final class SpectrumAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let setup: FFTSetup
    private let window: [Float]
    private let edges: [Int]
    private var pending: [Float] = []
    private var windowed = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var magnitudes = [Float](repeating: 0, count: 512)
    private var smoothed: [Float]
    private var ceiling: [Float]
    private var floor: [Float]
    private var average: [Float]
    private var lastPublish: CFTimeInterval = 0
    private let vocalRange: Range<Int>
    private var prevVocalDb: Float = -60
    private var vocalAvg: Float = -45

    init(bands: Int, sampleRate: Float) {
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { fatalError("vDSP FFT setup failed") }
        self.setup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 1024, isHalfWindow: false)
        let binHz = sampleRate / 1024
        edges = [Float(30), 150, 600, 2_500, 12_000].map { min(511, max(1, Int(($0 / binHz).rounded()))) }
        let vStart = min(511, max(1, Int((250.0 / binHz).rounded())))
        let vEnd = min(511, max(vStart + 1, Int((4000.0 / binHz).rounded())))
        vocalRange = vStart..<vEnd
        smoothed = [Float](repeating: 0, count: bands)
        ceiling = [Float](repeating: -30, count: bands)
        floor = [Float](repeating: -60, count: bands)
        average = [Float](repeating: -45, count: bands)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, onVocal: ((Float) -> Void)? = nil) -> [Float]? {
        stride(from: 0, to: samples.count - channels + 1, by: channels).forEach { i in
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i + c] }
            pending.append(sum / Float(channels))
        }
        guard pending.count >= n else { return nil }
        pending.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + $0.count - n, 1, window, 1, &windowed, 1, vDSP_Length(n)) }
        pending.removeFirst(max(0, pending.count - n / 2))

        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        if let onVocal {
            let slice = magnitudes[vocalRange]
            let power = slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count) / Float(n * n)
            let db = 10 * log10(max(power, 1e-12))
            let onset = min(1, max(0, (db - vocalAvg) / 7.0) * 0.5 + min(1, max(0, db - prevVocalDb) / 5.0) * 0.5)
            prevVocalDb = db
            vocalAvg += (db - vocalAvg) * 0.04
            onVocal(onset)
        }
        for b in 0..<smoothed.count {
            let slice = magnitudes[edges[b]..<max(edges[b] + 1, edges[b + 1])]
            let power = slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count) / Float(n * n)
            let db = 10 * log10(max(power, 1e-12))

            ceiling[b] = db > ceiling[b] ? db : ceiling[b] - 0.05
            floor[b] = db < floor[b] ? db : floor[b] + 0.02
            let range = max(ceiling[b] - floor[b], 18)
            let position = min(1, max(0, (db - (ceiling[b] - range)) / range))

            let onset = min(1, max(0, db - average[b]) / 8)
            average[b] += (db - average[b]) * 0.04
            let level = min(1, position * 0.35 + onset * 0.8)
            smoothed[b] += (level - smoothed[b]) * (level > smoothed[b] ? 0.75 : 0.22)
        }
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 24 else { return nil }
        lastPublish = now
        return smoothed
    }
}
