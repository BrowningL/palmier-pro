import Accelerate
import AVFoundation
import Foundation

struct DetectedBeat: Sendable, Equatable {
    /// Absolute source-media time, even when only a subrange was analysed.
    let sourceSeconds: Double
    /// Relative onset salience in this analysis, normalized to 0...1.
    let strength: Double
}

struct AudioBeatAnalysis: Sendable, Equatable {
    let tempoBPM: Double
    let confidence: Double
    let beats: [DetectedBeat]
}

enum AudioBeatDetectorError: LocalizedError {
    case invalidRange
    case invalidTempoRange
    case unexpectedPCMFormat
    case tooShort
    case noReliableBeat

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "The beat-analysis range must contain finite, non-negative times and have a positive duration."
        case .invalidTempoRange:
            "The beat-analysis tempo range is invalid."
        case .unexpectedPCMFormat:
            "The audio decoder did not provide mono 32-bit floating-point PCM."
        case .tooShort:
            "The audible range is too short to establish a reliable beat."
        case .noReliableBeat:
            "No reliable repeating beat was found. Try a more rhythmic section of the song."
        }
    }
}

/// Offline, on-device beat analysis for editing guides. PCM is streamed; memory
/// grows only with the compact onset envelope (about 86 values per second), not
/// with decoded sample count. Accelerate performs the windowing and DFT.
enum AudioBeatDetector {
    static let sampleRate: Double = 22_050
    static let frameSize = 1_024
    static let hopSize = 256
    static let hopSeconds = Double(hopSize) / sampleRate
    static let defaultTempoRange = 60.0...200.0

    private static let minimumAnalysisSeconds = 3.0

    static func analyze(
        from url: URL,
        range: ClosedRange<Double>? = nil,
        tempoRange: ClosedRange<Double> = defaultTempoRange,
        bpmOverride: Double? = nil
    ) async throws -> AudioBeatAnalysis {
        if let range {
            guard range.lowerBound.isFinite,
                  range.upperBound.isFinite,
                  range.lowerBound >= 0,
                  range.upperBound > range.lowerBound else {
                throw AudioBeatDetectorError.invalidRange
            }
            guard range.upperBound - range.lowerBound >= minimumAnalysisSeconds else {
                throw AudioBeatDetectorError.tooShort
            }
        }
        guard tempoRange.lowerBound.isFinite,
              tempoRange.upperBound.isFinite,
              tempoRange.lowerBound >= 30,
              tempoRange.upperBound <= 300,
              tempoRange.lowerBound < tempoRange.upperBound else {
            throw AudioBeatDetectorError.invalidTempoRange
        }
        if let bpmOverride {
            guard bpmOverride.isFinite, bpmOverride >= 30, bpmOverride <= 300 else {
                throw AudioBeatDetectorError.invalidTempoRange
            }
        }

        // Decode a short preroll for subranges. It gives the onset detector real
        // preceding audio, preserving a genuine beat exactly at the trim while
        // preventing the trim boundary itself from looking like an attack.
        let readRange: ClosedRange<Double>?
        if let range {
            let slowestRelevantTempo = bpmOverride ?? tempoRange.lowerBound
            let preroll = min(range.lowerBound, max(0.25, 60 / slowestRelevantTempo))
            readRange = (range.lowerBound - preroll)...range.upperBound
        } else {
            readRange = nil
        }
        let requestedSourceStart = readRange?.lowerBound ?? 0

        var extractor = try SpectralFluxExtractor()
        let readTiming: AudioTrackReader.ReadTiming
        do {
            readTiming = try await AudioTrackReader.read(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ], range: readRange) { buffer in
                try Task.checkCancellation()
                try extractor.consume(buffer)
            }
        } catch let error as AudioTrackReader.ReadError {
            switch error {
            case .noAudioTrack(let name):
                throw AudioEnvelopeError.noAudioTrack(name)
            case .readFailed(let reason):
                throw AudioEnvelopeError.readFailed(reason)
            }
        }
        extractor.finish()
        // Use the decoder's presentation timeline rather than assuming compressed
        // media starts exactly at the requested range boundary.
        let sourceStart = readTiming.firstPresentationSeconds ?? requestedSourceStart

        guard extractor.decodedSeconds >= minimumAnalysisSeconds else {
            throw AudioBeatDetectorError.tooShort
        }
        guard let tracked = BeatTracker.track(
            spectralFlux: extractor.flux,
            spectralLevels: extractor.spectralLevels,
            energyEnvelope: extractor.energyEnvelope,
            hopSeconds: hopSeconds,
            tempoRange: tempoRange,
            bpmOverride: bpmOverride
        ) else {
            throw AudioBeatDetectorError.noReliableBeat
        }

        let beats = tracked.indices.compactMap { index -> DetectedBeat? in
            // Centre quantisation can place a genuine boundary onset just before
            // its source time. A half-hop timestamp correction keeps that onset,
            // while strict range filtering prevents an actually trimmed-off beat
            // from being clamped to the clip start and shifting every-N cadence.
            let sourceSeconds = sourceStart + (Double(index) + 0.5) * hopSeconds
            if let range {
                guard range.contains(sourceSeconds) else { return nil }
            }
            return DetectedBeat(
                sourceSeconds: sourceSeconds,
                strength: tracked.strengths[index]
            )
        }
        return AudioBeatAnalysis(
            tempoBPM: tracked.tempoBPM,
            confidence: tracked.confidence,
            beats: beats
        )
    }
}

private struct SpectralFluxExtractor {
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zero: [Float]
    private let lowBand: Range<Int>
    private let midBand: Range<Int>
    private let highBand: Range<Int>

    private var pending: [Float]
    private var pendingOffset = 0
    private var decodedFrames = 0
    private var hasFinished = false
    private var previousSpectrum: [Float]
    private var currentSpectrum: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]

    private(set) var flux: [Double] = []
    private(set) var spectralLevels: [Double] = []
    private(set) var energyEnvelope: [Double] = []
    var decodedSeconds: Double {
        Double(decodedFrames) / AudioBeatDetector.sampleRate
    }

    init() throws {
        let count = AudioBeatDetector.frameSize
        dft = try vDSP.DiscreteFourierTransform<Float>(
            count: count,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: count,
            isHalfWindow: false
        )
        zero = [Float](repeating: 0, count: count)

        func bin(_ hertz: Double) -> Int {
            Int((hertz * Double(count) / AudioBeatDetector.sampleRate).rounded(.down))
        }
        lowBand = max(1, bin(40))..<max(2, bin(200))
        midBand = max(2, bin(200))..<max(3, bin(2_000))
        highBand = max(3, bin(2_000))..<min(count / 2, bin(8_000))

        // Half a window of leading silence centres the first feature at source t=0
        // instead of reporting the first transient roughly 46 ms early.
        pending = [Float](repeating: 0, count: count / 2)
        previousSpectrum = [Float](repeating: 0, count: count / 2)
        currentSpectrum = [Float](repeating: 0, count: count / 2)
        windowed = [Float](repeating: 0, count: count)
        real = [Float](repeating: 0, count: count)
        imaginary = [Float](repeating: 0, count: count)
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == 1,
              let channel = buffer.floatChannelData?[0] else {
            throw AudioBeatDetectorError.unexpectedPCMFormat
        }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        decodedFrames += count
        processAvailableWindows()
    }

    mutating func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        pending.append(contentsOf: repeatElement(0, count: AudioBeatDetector.frameSize / 2))
        processAvailableWindows()
    }

    private mutating func processAvailableWindows() {
        let frameSize = AudioBeatDetector.frameSize
        while pending.count - pendingOffset >= frameSize {
            let frame = pending[pendingOffset..<(pendingOffset + frameSize)]
            appendFlux(frame)
            pendingOffset += AudioBeatDetector.hopSize
        }

        // Compact in coarse chunks; removeFirst on every hop would turn a long song
        // into quadratic copying even though the detector itself is streaming.
        if pendingOffset >= frameSize * 4 {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private mutating func appendFlux(_ frame: ArraySlice<Float>) {
        var squareSum = 0.0
        for sample in frame {
            squareSum += Double(sample) * Double(sample)
        }
        energyEnvelope.append(sqrt(squareSum / Double(max(1, frame.count))))

        vDSP.multiply(frame, window, result: &windowed)
        dft.transform(
            inputReal: windowed,
            inputImaginary: zero,
            outputReal: &real,
            outputImaginary: &imaginary
        )

        for index in currentSpectrum.indices {
            let power = real[index] * real[index] + imaginary[index] * imaginary[index]
            currentSpectrum[index] = log1p(max(0, power).squareRoot())
        }

        func meanPositiveDifference(in band: Range<Int>) -> Double {
            guard !band.isEmpty else { return 0 }
            var sum = 0.0
            for index in band {
                sum += Double(max(0, currentSpectrum[index] - previousSpectrum[index]))
            }
            return sum / Double(band.count)
        }

        func meanLevel(in band: Range<Int>) -> Double {
            guard !band.isEmpty else { return 0 }
            var sum = 0.0
            for index in band { sum += Double(currentSpectrum[index]) }
            return sum / Double(band.count)
        }

        // Equalized bands keep thousands of high-frequency bins from drowning out
        // a kick drum while still retaining snare/hi-hat attacks.
        let value = 0.47 * meanPositiveDifference(in: lowBand)
            + 0.35 * meanPositiveDifference(in: midBand)
            + 0.18 * meanPositiveDifference(in: highBand)
        flux.append(value.isFinite ? value : 0)
        let level = 0.47 * meanLevel(in: lowBand)
            + 0.35 * meanLevel(in: midBand)
            + 0.18 * meanLevel(in: highBand)
        spectralLevels.append(level.isFinite ? level : 0)
        swap(&previousSpectrum, &currentSpectrum)
    }
}

private enum BeatTracker {
    struct Result {
        let tempoBPM: Double
        let confidence: Double
        let indices: [Int]
        let strengths: [Double]
    }

    static func track(
        spectralFlux: [Double],
        spectralLevels: [Double],
        energyEnvelope: [Double],
        hopSeconds: Double,
        tempoRange: ClosedRange<Double>,
        bpmOverride: Double?
    ) -> Result? {
        guard spectralFlux.count >= Int(2 / hopSeconds),
              spectralLevels.count == spectralFlux.count,
              energyEnvelope.count == spectralFlux.count,
              hopSeconds > 0 else { return nil }
        // A stationary tone can create a mathematically periodic, sub-percent FFT
        // scalloping pattern as its phase advances between overlapping windows.
        // Require either real loudness modulation or a scale-relative spectral
        // change before normalizing the novelty curve, otherwise that numerical
        // residue can be promoted into a convincing-looking beat grid.
        let inset = min(6, spectralFlux.count / 4)
        let interior = inset..<(spectralFlux.count - inset)
        let levels = interior.map { spectralLevels[$0] }.sorted()
        let energies = interior.map { energyEnvelope[$0] }.sorted()
        let levelFloor = max(percentile(levels, 0.90) * 1e-4, 1e-12)
        let relativeChanges = interior.map {
            spectralFlux[$0] / max(spectralLevels[$0], levelFloor)
        }.sorted()
        let energy90 = percentile(energies, 0.90)
        let energyContrast = (energy90 - percentile(energies, 0.10))
            / max(energy90, 1e-12)
        guard energyContrast >= 0.005 || percentile(relativeChanges, 0.95) >= 0.02 else {
            return nil
        }
        let novelty = adaptiveNovelty(spectralFlux, hopSeconds: hopSeconds)
        guard novelty.max() ?? 0 > 1e-6 else { return nil }

        let minLag = max(2, Int((60 / tempoRange.upperBound / hopSeconds).rounded()))
        let maxLag = min(
            novelty.count / 2,
            Int((60 / tempoRange.lowerBound / hopSeconds).rounded())
        )
        guard minLag < maxLag else { return nil }

        var correlations = [Int: Double]()
        for lag in minLag...maxLag {
            correlations[lag] = normalizedCorrelation(novelty, lag: lag)
        }
        var candidateScores = [Int: Double]()
        for lag in minLag...maxLag {
            let bpm = 60 / (Double(lag) * hopSeconds)
            // A gentle 120 BPM prior resolves exact half/double ties without
            // overpowering evidence from genuinely slower or faster music.
            let octaveDistance = log2(max(bpm, 1) / 120)
            let prior = exp(-0.5 * pow(octaveDistance / 0.75, 2))
            candidateScores[lag] = (correlations[lag] ?? 0) * (0.78 + 0.22 * prior)
        }

        let bestLag: Int
        let expectedPeriod: Double
        let reportedTempo: Double
        let overrideWasUsed = bpmOverride != nil
        if let bpmOverride {
            expectedPeriod = 60 / bpmOverride / hopSeconds
            bestLag = Int(expectedPeriod.rounded())
            guard bestLag >= 2, bestLag < novelty.count else { return nil }
            if correlations[bestLag] == nil {
                correlations[bestLag] = normalizedCorrelation(novelty, lag: bestLag)
            }
            reportedTempo = bpmOverride
        } else {
            // Dictionary iteration is intentionally not used for selection: half/
            // double-tempo ties must resolve identically on every process launch.
            var selectedLag = minLag
            var selectedScore = -Double.infinity
            var selectedPriorDistance = Double.infinity
            for lag in minLag...maxLag {
                let score = candidateScores[lag] ?? 0
                let bpm = 60 / (Double(lag) * hopSeconds)
                let priorDistance = abs(log2(max(bpm, 1) / 120))
                if score > selectedScore + 1e-12
                    || (abs(score - selectedScore) <= 1e-12
                        && (priorDistance < selectedPriorDistance - 1e-12
                            || (abs(priorDistance - selectedPriorDistance) <= 1e-12
                                && lag < selectedLag))) {
                    selectedLag = lag
                    selectedScore = score
                    selectedPriorDistance = priorDistance
                }
            }
            bestLag = selectedLag
            let left = correlations[bestLag - 1] ?? correlations[bestLag] ?? 0
            let center = correlations[bestLag] ?? 0
            let right = correlations[bestLag + 1] ?? center
            let denominator = left - 2 * center + right
            let adjustment = abs(denominator) > 1e-9
                ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator))
                : 0
            expectedPeriod = Double(bestLag) + adjustment
            reportedTempo = 60 / (expectedPeriod * hopSeconds)
        }

        let bestCorrelation = correlations[bestLag] ?? 0
        guard bestCorrelation >= 0.12 else { return nil }

        let beatIndices = dynamicBeatPath(novelty, period: expectedPeriod)
        guard beatIndices.count >= 3 else { return nil }
        let bestScore = candidateScores[bestLag] ?? bestCorrelation
        let runnerUp = candidateScores
            .filter { abs(Double($0.key - bestLag)) / Double(bestLag) > 0.10 }
            .map(\.value)
            .max() ?? 0
        let prominence = overrideWasUsed
            ? 1
            : max(0, min(1, (bestScore - runnerUp) / max(bestScore, 1e-9)))
        let coverage = Double(beatIndices.count(where: { novelty[$0] >= 0.12 }))
            / Double(beatIndices.count)
        let intervals = zip(beatIndices.dropFirst(), beatIndices).map { Double($0.0 - $0.1) }
        let deviation = median(intervals.map { abs($0 - expectedPeriod) })
        let regularity = exp(-deviation / max(1, expectedPeriod * 0.10))
        let periodicity = min(1, bestCorrelation / 0.35)
        let observedCycles = Double(novelty.count) / expectedPeriod
        let cycleSupport = min(1, max(0, (observedCycles - 1) / 4))
        let confidence = max(0, min(
            1,
            (0.45 * prominence + 0.35 * coverage + 0.20 * regularity)
                * periodicity * cycleSupport
        ))
        let strengths = normalizedStrengths(novelty)
        return Result(
            tempoBPM: reportedTempo,
            confidence: confidence,
            indices: beatIndices,
            strengths: strengths
        )
    }

    private static func adaptiveNovelty(_ flux: [Double], hopSeconds: Double) -> [Double] {
        let radius = max(2, Int((0.18 / hopSeconds).rounded()))
        var novelty = [Double](repeating: 0, count: flux.count)
        for index in flux.indices {
            let lower = max(0, index - radius)
            let upper = min(flux.count, index + radius + 1)
            let localMedian = median(Array(flux[lower..<upper]))
            novelty[index] = max(0, flux[index] - localMedian * 1.35)
        }

        if novelty.count >= 3 {
            let raw = novelty
            for index in 1..<(novelty.count - 1) {
                novelty[index] = 0.2 * raw[index - 1] + 0.6 * raw[index] + 0.2 * raw[index + 1]
            }
        }

        let positive = novelty.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return novelty }
        let scaleIndex = min(positive.count - 1, Int(Double(positive.count - 1) * 0.95))
        let scale = max(positive[scaleIndex], 1e-12)
        return novelty.map { min(1, $0 / scale) }
    }

    private static func normalizedCorrelation(_ values: [Double], lag: Int) -> Double {
        guard lag > 0, lag < values.count else { return 0 }
        var dot = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for index in lag..<values.count {
            let a = values[index]
            let b = values[index - lag]
            dot += a * b
            energyA += a * a
            energyB += b * b
        }
        let denominator = sqrt(energyA * energyB)
        guard denominator > 1e-12 else { return 0 }
        return max(0, min(1, dot / denominator))
    }

    private static func dynamicBeatPath(_ novelty: [Double], period: Double) -> [Int] {
        // A cut grid should not jump to a loud fill far between beats. Permit
        // ordinary live-performance drift, capped at about 46 ms at this hop.
        let tolerance = max(1, min(4, Int((period * 0.12).rounded())))
        var scores = [Double](repeating: 0, count: novelty.count)
        var predecessor = [Int](repeating: -1, count: novelty.count)

        for index in novelty.indices {
            var bestPrevious = 0.0
            var bestIndex = -1
            // Permit up to three missing onsets without losing the song's phase.
            // Candidate windows remain narrow, so this is linear in song length.
            for beatMultiple in 1...4 {
                let expectedInterval = period * Double(beatMultiple)
                let lowerInterval = max(1, Int(expectedInterval.rounded()) - tolerance)
                let upperInterval = Int(expectedInterval.rounded()) + tolerance
                for interval in lowerInterval...upperInterval where index >= interval {
                    let candidate = index - interval
                    let ratio = Double(interval) / expectedInterval
                    let missingBeatPenalty = 0.22 * Double(beatMultiple - 1)
                    let timingPenalty = 12 * pow(log2(max(ratio, 1e-9)), 2)
                        + missingBeatPenalty
                    let value = scores[candidate] - timingPenalty
                    if value > bestPrevious {
                        bestPrevious = value
                        bestIndex = candidate
                    }
                }
            }
            scores[index] = novelty[index] + bestPrevious
            predecessor[index] = bestIndex
        }

        guard let end = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[end] > 0 else {
            return []
        }
        var path: [Int] = []
        var cursor = end
        while cursor >= 0 {
            path.append(cursor)
            cursor = predecessor[cursor]
        }
        let observed = path.reversed()
        guard let first = observed.first else { return [] }
        var grid = [first]
        for current in observed.dropFirst() {
            let previous = grid.last!
            let beatSteps = max(1, Int((Double(current - previous) / period).rounded()))
            if beatSteps > 1 {
                for step in 1..<beatSteps {
                    grid.append(previous + Int((period * Double(step)).rounded()))
                }
            }
            grid.append(current)
        }
        return grid
    }

    private static func normalizedStrengths(_ novelty: [Double]) -> [Double] {
        let peak = max(novelty.max() ?? 0, 1e-12)
        return novelty.map { max(0, min(1, $0 / peak)) }
    }

    private static func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = min(
            sortedValues.count - 1,
            max(0, Int(Double(sortedValues.count - 1) * fraction))
        )
        return sortedValues[index]
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
