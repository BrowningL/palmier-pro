import AVFoundation
import Foundation

/// A streaming BS.1770 loudness measurement for one source audio track.
struct AudioLoudnessAnalysis: Sendable, Equatable {
    /// Integrated programme loudness after the BS.1770 absolute and relative gates.
    /// `nil` means the read range contained no measurable programme audio.
    let integratedLoudnessLUFS: Double?

    /// Highest decoded (unweighted) PCM sample. This is a sample peak, not a
    /// true-peak measurement. `nil` means every decoded sample was zero.
    let samplePeakDBFS: Double?

    /// Regions whose 100 ms loudness is plausibly active programme material.
    /// Values use source time, including `range.lowerBound` when a range is read.
    let activityRanges: [ClosedRange<Double>]
}

enum AudioLoudnessAnalyzerError: LocalizedError {
    case invalidRange
    case unexpectedPCMFormat

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            "The audio analysis range must contain finite, non-negative times and have a positive duration."
        case .unexpectedPCMFormat:
            "The audio decoder did not provide non-interleaved 32-bit floating-point PCM."
        }
    }
}

/// Measures decoded audio without retaining it in memory. The fixed sample rate
/// is an invariant: the K-weighting coefficients below are designed for 48 kHz.
enum AudioLoudnessAnalyzer {
    static let sampleRate: Double = 48_000
    static let hopSeconds: Double = 0.1

    // AVAssetReader can stall when a large parallel test/import workload opens
    // too many media decoders. Keep this limit at the decoder boundary so every
    // caller, not only Social Audio Mix, gets the same hardware-safe behavior.
    private static let decoderGate = AsyncSemaphore(value: 2)
    private static let hopFrameCount = Int(sampleRate * hopSeconds)
    private static let absoluteGateLUFS = -70.0
    private static let relativeGateOffsetLU = -10.0
    private static let activityFloorLUFS = -45.0
    private static let activityRelativeOffsetLU = -18.0
    private static let maximumActivityBridgeSeconds = 0.25
    private static let minimumActivitySeconds = 0.1
    private static let loudnessOffset = -0.691

    static func analyze(
        from url: URL,
        range: ClosedRange<Double>? = nil
    ) async throws -> AudioLoudnessAnalysis {
        if let range {
            guard range.lowerBound.isFinite,
                  range.upperBound.isFinite,
                  range.lowerBound >= 0,
                  range.upperBound > range.lowerBound else {
                throw AudioLoudnessAnalyzerError.invalidRange
            }
        }

        try await decoderGate.wait()
        defer { Task { await decoderGate.signal() } }

        var accumulator = StreamingAccumulator(hopFrameCount: hopFrameCount)
        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ], range: range) { buffer in
            // Asset readers commonly produce many buffers for long recordings;
            // checking here keeps cancellation latency bounded by one buffer.
            try Task.checkCancellation()
            try accumulator.consume(buffer)
        }
        accumulator.finish()

        let integratedLoudness = integratedLoudnessLUFS(for: accumulator.hops)
        let peak = decibels(amplitude: accumulator.samplePeak)
        let sourceStart = range?.lowerBound ?? 0
        let sourceLimit = range?.upperBound
        let activity = activityRanges(
            from: accumulator.hops,
            integratedLoudnessLUFS: integratedLoudness,
            sourceStartSeconds: sourceStart,
            sourceLimitSeconds: sourceLimit
        )

        return AudioLoudnessAnalysis(
            integratedLoudnessLUFS: integratedLoudness,
            samplePeakDBFS: peak,
            activityRanges: activity
        )
    }

    private static func integratedLoudnessLUFS(for hops: [HopEnergy]) -> Double? {
        // Four 100 ms hops form the 400 ms gating block required by BS.1770;
        // advancing one hop produces the prescribed 75% overlap.
        guard !hops.isEmpty else { return nil }
        var blockEnergies: [Double] = []
        blockEnergies.reserveCapacity(max(0, hops.count - 3))

        if hops.count >= 4 {
            for start in 0...(hops.count - 4) {
                let window = hops[start..<(start + 4)]
                // A partial final hop must not masquerade as a complete 400 ms block.
                guard window.allSatisfy({ $0.frameCount == hopFrameCount }) else { continue }
                let mean = window.reduce(0.0) { $0 + $1.meanWeightedSquare } / 4
                if mean.isFinite, mean > 0 {
                    blockEnergies.append(mean)
                }
            }
        }

        // BS.1770's gate needs a complete 400 ms block. Fast social edits can
        // legitimately be shorter, so use their duration-weighted programme
        // energy instead of silently leaving them unbalanced.
        if blockEnergies.isEmpty {
            let totalFrames = hops.reduce(0) { $0 + $1.frameCount }
            guard totalFrames > 0 else { return nil }
            let weightedEnergy = hops.reduce(0.0) {
                $0 + $1.meanWeightedSquare * Double($1.frameCount)
            } / Double(totalFrames)
            guard let loudness = loudnessLUFS(meanWeightedSquare: weightedEnergy),
                  loudness >= absoluteGateLUFS else { return nil }
            return loudness
        }

        let absoluteGated = blockEnergies.filter {
            guard let loudness = loudnessLUFS(meanWeightedSquare: $0) else { return false }
            return loudness >= absoluteGateLUFS
        }
        guard let preliminary = loudnessLUFS(
            meanWeightedSquare: arithmeticMean(absoluteGated)
        ) else { return nil }

        let relativeThreshold = preliminary + relativeGateOffsetLU
        let relativeGated = absoluteGated.filter {
            guard let loudness = loudnessLUFS(meanWeightedSquare: $0) else { return false }
            return loudness >= relativeThreshold
        }
        return loudnessLUFS(meanWeightedSquare: arithmeticMean(relativeGated))
    }

    private static func activityRanges(
        from hops: [HopEnergy],
        integratedLoudnessLUFS: Double?,
        sourceStartSeconds: Double,
        sourceLimitSeconds: Double?
    ) -> [ClosedRange<Double>] {
        guard let integratedLoudnessLUFS, integratedLoudnessLUFS.isFinite else { return [] }
        let threshold = max(
            activityFloorLUFS,
            integratedLoudnessLUFS + activityRelativeOffsetLU
        )

        var active: [ClosedRange<Double>] = []
        active.reserveCapacity(hops.count)
        var elapsedFrames = 0

        for hop in hops {
            let start = sourceStartSeconds + Double(elapsedFrames) / sampleRate
            elapsedFrames += hop.frameCount
            var end = sourceStartSeconds + Double(elapsedFrames) / sampleRate
            if let sourceLimitSeconds { end = min(end, sourceLimitSeconds) }

            guard end > start,
                  let loudness = loudnessLUFS(meanWeightedSquare: hop.meanWeightedSquare),
                  loudness >= threshold else { continue }
            active.append(start...end)
        }

        var bridged: [ClosedRange<Double>] = []
        for range in active {
            if let previous = bridged.last,
               range.lowerBound - previous.upperBound <= maximumActivityBridgeSeconds + 1e-9 {
                bridged[bridged.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
            } else {
                bridged.append(range)
            }
        }

        return bridged.filter {
            $0.upperBound - $0.lowerBound + 1e-9 >= minimumActivitySeconds
        }
    }

    private static func arithmeticMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return mean.isFinite && mean > 0 ? mean : nil
    }

    private static func loudnessLUFS(meanWeightedSquare: Double?) -> Double? {
        guard let meanWeightedSquare,
              meanWeightedSquare.isFinite,
              meanWeightedSquare > 0 else { return nil }
        let value = loudnessOffset + 10 * log10(meanWeightedSquare)
        return value.isFinite ? value : nil
    }

    private static func decibels(amplitude: Double) -> Double? {
        guard amplitude.isFinite, amplitude > 0 else { return nil }
        let value = 20 * log10(amplitude)
        return value.isFinite ? value : nil
    }
}

private struct HopEnergy {
    let meanWeightedSquare: Double
    let frameCount: Int
}

private struct StreamingAccumulator {
    private let hopFrameCount: Int
    private var filters: [KWeightingFilter] = []
    private var currentEnergy = 0.0
    private var currentFrames = 0

    private(set) var hops: [HopEnergy] = []
    private(set) var samplePeak = 0.0

    init(hopFrameCount: Int) {
        self.hopFrameCount = hopFrameCount
    }

    mutating func consume(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData else {
            throw AudioLoudnessAnalyzerError.unexpectedPCMFormat
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return }

        if filters.isEmpty {
            filters = Array(repeating: KWeightingFilter(), count: channelCount)
        } else if filters.count != channelCount {
            // A track is expected to retain its channel layout. Resetting here is
            // safer than indexing stale state if a malformed asset changes it.
            filters = Array(repeating: KWeightingFilter(), count: channelCount)
        }

        for frame in 0..<frameCount {
            var frameEnergy = 0.0
            for channel in 0..<channelCount {
                let decoded = Double(channels[channel][frame])
                // Non-finite PCM must not poison the recursive filter state or
                // turn an otherwise valid result into NaN.
                let sample = decoded.isFinite ? decoded : 0
                samplePeak = max(samplePeak, abs(sample))

                let weighted = filters[channel].process(sample)
                if weighted.isFinite {
                    frameEnergy += weighted * weighted
                } else {
                    filters[channel] = KWeightingFilter()
                }
            }

            if frameEnergy.isFinite {
                currentEnergy += frameEnergy
            }
            currentFrames += 1
            if currentFrames == hopFrameCount {
                appendCurrentHop()
            }
        }
    }

    mutating func finish() {
        if currentFrames > 0 {
            appendCurrentHop()
        }
    }

    private mutating func appendCurrentHop() {
        guard currentFrames > 0 else { return }
        let mean = currentEnergy / Double(currentFrames)
        hops.append(HopEnergy(
            meanWeightedSquare: mean.isFinite && mean > 0 ? mean : 0,
            frameCount: currentFrames
        ))
        currentEnergy = 0
        currentFrames = 0
    }
}

private struct KWeightingFilter {
    private var shelf = Biquad(
        b0: 1.53512485958697,
        b1: -2.69169618940638,
        b2: 1.19839281085285,
        a1: -1.69065929318241,
        a2: 0.73248077421585
    )
    private var highPass = Biquad(
        b0: 1,
        b1: -2,
        b2: 1,
        a1: -1.99004745483398,
        a2: 0.99007225036621
    )

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

private struct Biquad {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    private var x1 = 0.0
    private var x2 = 0.0
    private var y1 = 0.0
    private var y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    mutating func process(_ x0: Double) -> Double {
        let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x0
        y2 = y1
        y1 = y0
        return y0
    }
}
