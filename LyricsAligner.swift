import Foundation

struct LyricsAlignment: Equatable, Sendable {
    let offset: Double
    let confidence: Double
}

enum LyricsAligner {
    static let frameDuration = 0.02
    static let maxOffset = 5.0
    static let minConfidence = 0.40

    static func align(lines: [LyricLine], heardOnsets: [(time: Double, onset: Float)]) -> LyricsAlignment? {
        guard !lines.isEmpty, !heardOnsets.isEmpty else { return nil }
        guard let maxTime = heardOnsets.map(\.time).max(), maxTime >= 3.0 else { return nil }

        let activeLines = lines.filter { $0.time <= maxTime + maxOffset }
        guard !activeLines.isEmpty else { return nil }

        let n = Int(ceil(maxTime / frameDuration)) + 1
        var rawHeard = [Float](repeating: 0, count: n)
        for sample in heardOnsets {
            let idx = Int(round(sample.time / frameDuration))
            if idx >= 0 && idx < n {
                rawHeard[idx] = max(rawHeard[idx], sample.onset)
            }
        }

        var smoothedHeard = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let prev = i > 0 ? rawHeard[i - 1] : rawHeard[i]
            let curr = rawHeard[i]
            let next = i + 1 < n ? rawHeard[i + 1] : rawHeard[i]
            smoothedHeard[i] = prev * 0.25 + curr * 0.5 + next * 0.25
        }

        var expectedGrid = [Float](repeating: 0, count: n)
        for line in activeLines {
            let center = Int(round(line.time / frameDuration))
            for (d, w) in [(-2, 0.2), (-1, 0.6), (0, 1.0), (1, 0.6), (2, 0.2)] {
                let idx = center + d
                if idx >= 0 && idx < n {
                    expectedGrid[idx] = max(expectedGrid[idx], Float(w))
                }
            }
            let startIdx = max(0, Int(round(line.time / frameDuration)))
            let endIdx = min(n - 1, Int(round(line.end / frameDuration)))
            if endIdx > startIdx {
                for j in startIdx...endIdx {
                    expectedGrid[j] = max(expectedGrid[j], 0.15)
                }
            }
        }

        let maxShiftFrames = Int(round(maxOffset / frameDuration))

        func evalShift(_ s: Int) -> Float {
            let hStart = max(0, -s)
            let hEnd = min(n, n - s)
            let count = hEnd - hStart
            guard count >= 100 else { return 0 }

            var hSum: Float = 0
            var eSum: Float = 0
            for i in hStart..<hEnd {
                hSum += smoothedHeard[i]
                eSum += expectedGrid[i + s]
            }
            let hMean = hSum / Float(count)
            let eMean = eSum / Float(count)

            var num: Float = 0
            var hDenom: Float = 0
            var eDenom: Float = 0
            for i in hStart..<hEnd {
                let hDiff = smoothedHeard[i] - hMean
                let eDiff = expectedGrid[i + s] - eMean
                num += hDiff * eDiff
                hDenom += hDiff * hDiff
                eDenom += eDiff * eDiff
            }
            let denom = sqrt(hDenom * eDenom)
            return denom > 1e-6 ? num / denom : 0
        }

        var bestCoarseS = 0
        var bestCoarseScore: Float = -1
        var coarseScores: [Int: Float] = [:]
        for s in stride(from: -maxShiftFrames, through: maxShiftFrames, by: 2) {
            let sc = evalShift(s)
            coarseScores[s] = sc
            if sc > bestCoarseScore {
                bestCoarseScore = sc
                bestCoarseS = s
            }
        }
        guard bestCoarseScore > 0.1 else { return nil }

        var bestS = bestCoarseS
        var bestScore = bestCoarseScore
        for s in [bestCoarseS - 1, bestCoarseS + 1] {
            if s >= -maxShiftFrames && s <= maxShiftFrames {
                let sc = evalShift(s)
                coarseScores[s] = sc
                if sc > bestScore {
                    bestScore = sc
                    bestS = s
                }
            }
        }

        let y0 = bestScore
        let yMinus = evalShift(bestS - 1)
        let yPlus = evalShift(bestS + 1)
        let denom = 2.0 * (2.0 * y0 - yMinus - yPlus)
        let delta = denom > 1e-6 ? (yPlus - yMinus) / denom : 0
        let refinedS = Float(bestS) + max(-0.5, min(0.5, delta))
        let detectedShift = Double(refinedS) * frameDuration

        let runnerUp = coarseScores.filter { abs($0.key - bestS) > 25 }.map(\.value).max() ?? 0
        let sharpness = max(0, min(1.0, (bestScore - max(0, runnerUp)) / (bestScore + 1e-4)))
        let confidence = Double(0.5 * min(1.0, max(0, bestScore / 0.5)) + 0.5 * sharpness)

        guard confidence >= minConfidence else { return nil }
        return LyricsAlignment(offset: detectedShift, confidence: confidence)
    }
}
