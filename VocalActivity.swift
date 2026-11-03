import Accelerate
import Foundation
import os

struct VocalActivity: Sendable {
    let presence: [Float]
    let onsets: [Float]
    let originMs: Float
    var frames: Int { presence.count }
    static let frameMs = 10
}

final class VocalActivityAnalyzer: @unchecked Sendable {
    private static let sampleRate = 16_000, frameSize = 512, hopSize = 160, bins = 257, minFrames = 1_500
    private static let hzPerBin = Float(sampleRate) / Float(frameSize)
    private static let bandFrom = 8, bandTo = 128, tonalFrom = 9, tonalTo = 96
    private static let bandWeight = (0..<bins).map { bin -> Float in
        let hz = Float(bin) * hzPerBin; return (hz >= 300 && hz <= 3400) ? 1.0 : 0.5
    }
    private static let window = (0..<frameSize).map { i in
        Float(0.5 - 0.5 * cos(2.0 * .pi * Double(i) / Double(frameSize - 1)))
    }

    private var lock = os_unfair_lock()
    private let setup: FFTSetup
    private var midRing = [Float](repeating: 0, count: frameSize)
    private var sideRing = [Float](repeating: 0, count: frameSize)
    private var real = [Float](repeating: 0, count: frameSize)
    private var imaginary = [Float](repeating: 0, count: frameSize)
    private var previousLog = [Float](repeating: 0, count: bins)
    private var writeIndex = 0, totalSamples: Int64 = 0
    private var energyDb: [Float] = [], share: [Float] = [], tonality: [Float] = [], flux: [Float] = []
    private var resampler: StereoResampler?, originMs: Float?

    init() {
        guard let s = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else { fatalError("FFT setup failed") }
        self.setup = s
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    @discardableResult
    func feed(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Float, presentationMs: Double = 0.0) -> Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if originMs == nil { originMs = Float(presentationMs) + 16.0 }
        let rate = Int(sampleRate)
        let r = (resampler?.inputRate == rate) ? resampler! : {
            let created = StereoResampler(inputRate: rate); resampler = created; return created
        }()
        r.push(samples, channels: channels) { [weak self] mid, side in self?.addSample(mid: mid, side: side) }
        return totalSamples >= 400_000
    }

    func finish() -> VocalActivity? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        guard energyDb.count >= Self.minFrames else { return nil }
        let e = Self.normalised(energyDb), s = Self.normalised(share), t = Self.normalised(tonality)
        let raw = (0..<energyDb.count).map { 0.6 * e[$0] + 0.2 * s[$0] + 0.2 * t[$0] }
        return VocalActivity(presence: Self.movingAverage(raw, radius: 3),
                             onsets: Self.onsetEnvelope(flux), originMs: originMs ?? 16.0)
    }

    private func addSample(mid: Float, side: Float) {
        midRing[writeIndex] = mid; sideRing[writeIndex] = side
        writeIndex = (writeIndex + 1) & (Self.frameSize - 1)
        totalSamples += 1
        if totalSamples >= Self.frameSize && (totalSamples - Int64(Self.frameSize)) % Int64(Self.hopSize) == 0 {
            analyzeFrame()
        }
    }

    private func analyzeFrame() {
        for i in 0..<Self.frameSize {
            let at = (writeIndex + i) & (Self.frameSize - 1)
            real[i] = midRing[at] * Self.window[i]; imaginary[i] = sideRing[at] * Self.window[i]
        }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
            }
        }
        var bandEnergy: Float = 0, allEnergy: Float = 0, rise: Float = 0, logSum: Float = 0, flatnessEnergy: Float = 0
        var flatnessBins = 0
        for bin in 1..<Self.bins {
            let mirror = Self.frameSize - bin, a = real[bin], b = imaginary[bin], c = real[mirror], d = imaginary[mirror]
            let midRe = (a + c) * 0.5, midIm = (b - d) * 0.5, sideRe = (b + d) * 0.5, sideIm = (c - a) * 0.5
            let midPower = midRe * midRe + midIm * midIm, sidePower = sideRe * sideRe + sideIm * sideIm
            allEnergy += midPower
            let centered = max(0, midPower - sidePower)
            if bin >= Self.bandFrom && bin <= Self.bandTo {
                bandEnergy += centered * Self.bandWeight[bin]
                let compressed = log(1.0 + 1000.0 * sqrt(centered))
                let up = compressed - previousLog[bin]
                if up > 0 { rise += up }
                previousLog[bin] = compressed
            }
            if bin >= Self.tonalFrom && bin <= Self.tonalTo {
                logSum += log(centered + 1e-10); flatnessEnergy += centered; flatnessBins += 1
            }
        }
        energyDb.append(10.0 * log10(bandEnergy + 1e-10))
        share.append(allEnergy > 0 ? bandEnergy / allEnergy : 0)
        let flatness = (flatnessBins > 0 && flatnessEnergy > 0)
            ? min(1.0, max(0.0, exp(logSum / Float(flatnessBins)) / (flatnessEnergy / Float(flatnessBins)))) : 1.0
        tonality.append(1.0 - flatness)
        flux.append(rise / Float(Self.bandTo - Self.bandFrom + 1))
    }

    private static func onsetEnvelope(_ raw: [Float]) -> [Float] {
        var prefix = [Double](repeating: 0, count: raw.count + 1)
        for i in 0..<raw.count { prefix[i + 1] = prefix[i] + Double(raw[i]) }
        var out = [Float](repeating: 0, count: raw.count)
        for i in 0..<raw.count {
            let from = max(0, i - 25), to = min(raw.count, i + 26)
            out[i] = max(0, raw[i] - Float((prefix[to] - prefix[from]) / Double(to - from)))
        }
        let top = percentile(out, 0.98)
        guard top > 1e-6 else { return out }
        return out.map { min(1.0, $0 / top) }
    }

    private static func normalised(_ v: [Float]) -> [Float] {
        let low = percentile(v, 0.15), high = percentile(v, 0.97), span = high - low
        guard span > 1e-6 else { return [Float](repeating: 0, count: v.count) }
        return v.map { min(1.0, max(0.0, ($0 - low) / span)) }
    }

    private static func percentile(_ v: [Float], _ frac: Float) -> Float {
        guard !v.isEmpty else { return 0 }
        let sorted = v.sorted()
        return sorted[min(max(Int(Float(sorted.count) * frac), 0), sorted.count - 1)]
    }

    private static func movingAverage(_ v: [Float], radius: Int) -> [Float] {
        var prefix = [Double](repeating: 0, count: v.count + 1)
        for i in 0..<v.count { prefix[i + 1] = prefix[i] + Double(v[i]) }
        return (0..<v.count).map { i in
            let from = max(0, i - radius), to = min(v.count, i + radius + 1)
            return Float((prefix[to] - prefix[from]) / Double(to - from))
        }
    }
}

private final class StereoResampler {
    let inputRate: Int
    private let step: Double, filtering: Bool
    private let left0: Biquad, left1: Biquad, right0: Biquad, right1: Biquad
    private var position = 0.0, prevL: Float = 0, prevR: Float = 0

    init(inputRate: Int, outputRate: Int = 16_000, cutoffHz: Double = 6_500.0) {
        self.inputRate = inputRate
        self.step = Double(inputRate) / Double(outputRate)
        self.filtering = inputRate > outputRate
        self.left0 = Biquad.lowPass(rate: inputRate, cutoff: cutoffHz, q: 0.5412)
        self.left1 = Biquad.lowPass(rate: inputRate, cutoff: cutoffHz, q: 1.3066)
        self.right0 = Biquad.lowPass(rate: inputRate, cutoff: cutoffHz, q: 0.5412)
        self.right1 = Biquad.lowPass(rate: inputRate, cutoff: cutoffHz, q: 1.3066)
    }

    func push(_ samples: UnsafeBufferPointer<Float>, channels: Int, emit: (Float, Float) -> Void) {
        let count = samples.count / channels
        for i in 0..<count {
            let base = i * channels
            var l = samples[base], r = channels >= 2 ? samples[base + 1] : l
            if filtering { l = left1.process(left0.process(l)); r = right1.process(right0.process(r)) }
            while position <= 1.0 {
                let t = Float(position), sL = prevL + (l - prevL) * t, sR = prevR + (r - prevR) * t
                emit((sL + sR) * 0.5, (sL - sR) * 0.5)
                position += step
            }
            position -= 1.0; prevL = l; prevR = r
        }
    }
}

private final class Biquad {
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y; return y
    }

    static func lowPass(rate: Int, cutoff: Double, q: Double) -> Biquad {
        let k = tan(.pi * cutoff / Double(rate)), norm = 1.0 / (1.0 + k / q + k * k)
        let b0 = Float(k * k * norm)
        return Biquad(b0: b0, b1: 2.0 * b0, b2: b0,
                      a1: Float(2.0 * (k * k - 1.0) * norm),
                      a2: Float((1.0 - k / q + k * k) * norm))
    }
}
