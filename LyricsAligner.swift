import Foundation

struct Alignment: Equatable, Sendable {
    let offsetMs: Int
    let confidence: Float
    let strongLines: Int
    let totalLines: Int
}

enum LyricsAligner {
    private static let vowels = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüýÿąęėīįōőūűų")

    struct LineSpan { let startMs: Int64; let endMs: Int64 }
    struct Expected { let presence: [Float]; let onsets: [Float]; let spans: [LineSpan] }
    struct LineOffset { let span: LineSpan; let offsetMs: Float; let strength: Float }

    static func expectedSinging(lines: [LyricLine]) -> Expected? {
        let sung = lines.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !sung.isEmpty else { return nil }
        var spans: [LineSpan] = []
        var words: [(from: Int64, to: Int64, weight: Float)] = []
        var starts: [(at: Int64, weight: Float)] = []
        for (idx, line) in sung {
            let start = Int64((line.time * 1000.0).rounded())
            let nextStart = sung.first(where: { $0.offset > idx }).map { Int64(($0.element.time * 1000.0).rounded()) } ?? (start + 7000)
            let guess = min(max(Int64(syllables(line.text) * 260), 700), 7000)
            let end = max(start + 300, min(nextStart - 50, start + guess))
            words.append((from: start, to: end, weight: 1.0))
            starts.append((at: start, weight: 1.5))
            spans.append(LineSpan(startMs: start, endMs: end))
        }
        let endMs = (words.map { $0.to }.max() ?? 0) + 2000
        let size = Int(endMs / 10) + 1
        var presence = [Float](repeating: 0, count: size)
        for w in words {
            let a = min(size, max(0, Int(w.from / 10))), b = min(size, max(0, Int(w.to / 10)))
            for g in a..<b {
                let tail = min(1.0, Float(b - g) / 20.0)
                presence[g] = max(presence[g], w.weight * tail)
            }
        }
        var impulses = [Float](repeating: 0, count: size)
        for s in starts {
            let g = Int(s.at / 10)
            if g >= 0 && g < size { impulses[g] = max(impulses[g], s.weight) }
        }
        return Expected(presence: presence, onsets: gaussianBlur(impulses, sigma: 8.0), spans: spans)
    }

    static func syllables(_ text: String) -> Int {
        var count = 0, inVowel = false
        for ch in text {
            let s = ch.unicodeScalars.first?.value ?? 0
            if (0x4E00...0x9FFF).contains(s) || (0x3400...0x4DBF).contains(s) ||
               (0x3040...0x309F).contains(s) || (0x30A0...0x30FF).contains(s) || (0xAC00...0xD7AF).contains(s) {
                count += 1; inVowel = false
            } else if let lower = ch.lowercased().first, vowels.contains(lower) {
                if !inVowel { count += 1 }
                inVowel = true
            } else { inVowel = false }
        }
        return max(1, count)
    }

    static func align(lines: [LyricLine], vocals: VocalActivity, maxOffsetMs: Int = 4000) -> Alignment? {
        guard let expected = expectedSinging(lines: lines), expected.spans.count >= 4 else { return nil }
        let heardVoice = zscore(vocals.presence), heardOnsets = zscore(vocals.onsets)
        let wantedVoice = zscore(expected.presence), wantedOnsets = zscore(expected.onsets)
        let maxShift = maxOffsetMs / 10, coarseMax = maxShift / 4
        let coarseVoice = downsample(heardVoice, 4), coarseOnsets = downsample(heardOnsets, 4)
        let coarseWantedVoice = downsample(wantedVoice, 4), coarseWantedOnsets = downsample(wantedOnsets, 4)

        var coarse = [Float](repeating: 0, count: coarseMax * 2 + 1)
        for i in 0..<coarse.count {
            let shift = i - coarseMax
            coarse[i] = correlate(coarseVoice, coarseWantedVoice, shift) + 0.35 * correlate(coarseOnsets, coarseWantedOnsets, shift)
        }
        guard let coarseBest = coarse.indices.max(by: { coarse[$0] < coarse[$1] }) else { return nil }
        let best = coarse[coarseBest]
        guard best > 0, abs(coarseBest - coarseMax) < coarseMax - 1 else { return nil }

        var runnerUp: Float = 0
        for i in 0..<coarse.count where abs(i - coarseBest) > 40 {
            if coarse[i] > runnerUp { runnerUp = coarse[i] }
        }
        let sharpness = min(1.0, max(0.0, (best - runnerUp) / (abs(best) + 1e-3)))
        guard sharpness >= 0.25 else { return nil }

        let center = (coarseBest - coarseMax) * 4
        var fine: [Int: Float] = [:]
        for s in (center - 6)...(center + 6) {
            fine[s] = correlate(heardVoice, wantedVoice, s) + 0.35 * correlate(heardOnsets, wantedOnsets, s)
        }
        guard let shift = fine.max(by: { $0.value < $1.value })?.key else { return nil }
        let globalOffset = Float(shift * 10) + subFrame(fine, shift) - vocals.originMs
        let voiceAgreement = correlate(heardVoice, wantedVoice, shift)

        let lineOffsets = refineLines(expected.spans, shift, heardVoice, heardOnsets, wantedVoice, wantedOnsets, 1.0, vocals.originMs)
        let strong = lineOffsets.filter { $0.strength >= 1.6 }
        let offset = strong.count >= 3 ? weightedMedian(strong) : globalOffset
        let agrees = abs(offset - globalOffset) <= 150.0

        let confidence = (
            0.55 * min(1.0, max(0.0, sharpness / 0.6)) +
            0.30 * min(1.0, max(0.0, voiceAgreement / 0.45)) +
            0.15 * Float(strong.count) / Float(lineOffsets.count)
        ) * (agrees ? 1.0 : 0.75)

        return Alignment(
            offsetMs: min(maxOffsetMs, max(-maxOffsetMs, Int((offset / 10.0).rounded() * 10))),
            confidence: min(1.0, max(0.0, confidence)),
            strongLines: strong.count,
            totalLines: lineOffsets.count
        )
    }

    private static func refineLines(
        _ spans: [LineSpan], _ shift: Int,
        _ heardVoice: [Float], _ heardOnsets: [Float],
        _ wantedVoice: [Float], _ wantedOnsets: [Float],
        _ onsetWeight: Float, _ originMs: Float
    ) -> [LineOffset] {
        let states = 81, slack = 40, margin = 30
        var scores: [[Float]] = []
        scores.reserveCapacity(spans.count)
        for span in spans {
            let from = Int(span.startMs / 10) - margin, to = Int(span.endMs / 10) + margin
            var raw = [Float](repeating: 0, count: states)
            for s in 0..<states {
                let lineShift = shift + s - slack
                raw[s] = correlateWindow(heardVoice, wantedVoice, lineShift, from, to)
                    + onsetWeight * correlateWindow(heardOnsets, wantedOnsets, lineShift, from, to)
            }
            scores.append(zscore(raw))
        }
        var total = Array(repeating: [Float](repeating: 0, count: states), count: spans.count)
        var from = Array(repeating: [Int](repeating: 0, count: states), count: spans.count)
        total[0] = scores[0]
        for i in 1..<spans.count {
            for s in 0..<states {
                var bestVal = -Float.infinity, bestP = s
                for p in 0..<states {
                    let v = total[i - 1][p] - 0.04 * Float(abs(s - p))
                    if v > bestVal { bestVal = v; bestP = p }
                }
                total[i][s] = bestVal + scores[i][s]; from[i][s] = bestP
            }
        }
        var chosen = [Int](repeating: 0, count: spans.count)
        chosen[spans.count - 1] = total[spans.count - 1].indices.max(by: { total[spans.count - 1][$0] < total[spans.count - 1][$1] }) ?? 0
        for i in stride(from: spans.count - 1, through: 1, by: -1) { chosen[i - 1] = from[i][chosen[i]] }
        return spans.indices.map { i in
            let s = chosen[i], frames = s - slack
            return LineOffset(span: spans[i], offsetMs: Float((shift + frames) * 10) - originMs, strength: scores[i][s])
        }
    }

    private static func weightedMedian(_ lines: [LineOffset]) -> Float {
        let sorted = lines.sorted { $0.offsetMs < $1.offsetMs }
        let half = sorted.reduce(0.0) { $0 + Double($1.strength) } / 2.0
        var running = 0.0
        for l in sorted {
            running += Double(l.strength)
            if running >= half { return l.offsetMs }
        }
        return sorted.last?.offsetMs ?? 0
    }

    private static func correlate(_ heard: [Float], _ wanted: [Float], _ shift: Int) -> Float {
        let start = max(0, -shift), end = min(heard.count, wanted.count - shift)
        guard end > start else { return 0 }
        var sum = 0.0
        for f in start..<end { sum += Double(heard[f] * wanted[f + shift]) }
        return Float(sum / Double(end - start))
    }

    private static func correlateWindow(_ heard: [Float], _ wanted: [Float], _ shift: Int, _ from: Int, _ to: Int) -> Float {
        let start = max(from, max(0, shift)), end = min(to, min(wanted.count, heard.count + shift))
        guard end > start else { return 0 }
        var sum = 0.0
        for g in start..<end { sum += Double(heard[g - shift] * wanted[g]) }
        return Float(sum / Double(end - start))
    }

    private static func subFrame(_ scores: [Int: Float], _ peak: Int) -> Float {
        guard let left = scores[peak - 1], let middle = scores[peak], let right = scores[peak + 1] else { return 0 }
        let curve = left - 2.0 * middle + right
        guard curve < 0 else { return 0 }
        return min(0.5, max(-0.5, 0.5 * (left - right) / curve)) * 10.0
    }

    private static func zscore(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let mean = v.reduce(0.0) { $0 + Double($1) } / Double(v.count)
        var devSq = 0.0
        for x in v { let d = Double(x) - mean; devSq += d * d }
        let dev = Float(sqrt(devSq / Double(v.count)))
        guard dev > 1e-6 else { return [Float](repeating: 0, count: v.count) }
        return v.map { ($0 - Float(mean)) / dev }
    }

    private static func downsample(_ v: [Float], _ factor: Int) -> [Float] {
        let count = v.count / factor
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0, b = i * factor
            for j in 0..<factor { sum += v[b + j] }
            out[i] = sum / Float(factor)
        }
        return out
    }

    private static func gaussianBlur(_ v: [Float], sigma: Float) -> [Float] {
        let radius = Int(sigma * 3)
        let kernel = (0...radius * 2).map { i in exp(-Float((i - radius) * (i - radius)) / (2.0 * sigma * sigma)) }
        var out = [Float](repeating: 0, count: v.count)
        for i in 0..<v.count where v[i] > 0 {
            for k in 0..<kernel.count {
                let at = i + k - radius
                if at >= 0 && at < v.count { out[at] = max(out[at], v[i] * kernel[k]) }
            }
        }
        return out
    }
}
