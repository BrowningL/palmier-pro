import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio loudness analyzer")
struct AudioLoudnessAnalyzerTests {
    @Test func silenceHasNoFiniteMeasurementOrActivity() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 1, channels: 1) { _, _ in 0 }

        let analysis = try await AudioLoudnessAnalyzer.analyze(from: url)

        #expect(analysis.integratedLoudnessLUFS == nil)
        #expect(analysis.samplePeakDBFS == nil)
        #expect(analysis.activityRanges.isEmpty)
    }

    @Test func measuresKWeightedMonoLoudnessAndSamplePeak() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 2, channels: 1) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }

        let analysis = try await AudioLoudnessAnalyzer.analyze(from: url)
        let loudness = try #require(analysis.integratedLoudnessLUFS)
        let peak = try #require(analysis.samplePeakDBFS)

        // A 1 kHz sine is close to the BS.1770 reference point after K-weighting.
        #expect(abs(loudness + 23.0) < 0.12)
        #expect(abs(peak + 20.0) < 0.01)
        #expect(analysis.activityRanges.count == 1)
        #expect(abs((analysis.activityRanges.first?.lowerBound ?? -1) - 0) < 0.001)
        #expect(abs((analysis.activityRanges.first?.upperBound ?? -1) - 2) < 0.001)
    }

    @Test func intermediateDenoiseStrengthMeasuresTheRenderedDryWetBlend() async throws {
        let dryURL = temporaryAudioURL()
        let wetURL = temporaryAudioURL()
        defer {
            try? FileManager.default.removeItem(at: dryURL)
            try? FileManager.default.removeItem(at: wetURL)
        }
        try writeAudio(to: dryURL, duration: 1, channels: 1) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }
        try writeAudio(to: wetURL, duration: 1, channels: 1) { _, _ in 0 }

        let dry = try await AudioLoudnessAnalyzer.analyze(from: dryURL)
        let blend = try await AudioLoudnessAnalyzer.analyzeBlend(
            dryURL: dryURL,
            wetURL: wetURL,
            strength: 0.6
        )
        let expectedDelta = 20 * log10(0.4)
        let loudnessDelta = try #require(blend.integratedLoudnessLUFS)
            - (try #require(dry.integratedLoudnessLUFS))
        let peakDelta = try #require(blend.samplePeakDBFS)
            - (try #require(dry.samplePeakDBFS))

        #expect(abs(loudnessDelta - expectedDelta) < 0.08)
        #expect(abs(peakDelta - expectedDelta) < 0.02)
    }

    @Test func stereoChannelsContributeIndependentlyToProgrammeLoudness() async throws {
        let monoURL = temporaryAudioURL()
        let stereoURL = temporaryAudioURL()
        defer {
            try? FileManager.default.removeItem(at: monoURL)
            try? FileManager.default.removeItem(at: stereoURL)
        }
        try writeAudio(to: monoURL, duration: 1, channels: 1) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }
        try writeAudio(to: stereoURL, duration: 1, channels: 2) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }

        let mono = try await AudioLoudnessAnalyzer.analyze(from: monoURL)
        let stereo = try await AudioLoudnessAnalyzer.analyze(from: stereoURL)
        let monoLoudness = try #require(mono.integratedLoudnessLUFS)
        let stereoLoudness = try #require(stereo.integratedLoudnessLUFS)

        #expect(abs((stereoLoudness - monoLoudness) - 3.0103) < 0.02)
        #expect(abs(try #require(stereo.samplePeakDBFS) + 20) < 0.01)
    }

    @Test func relativeGateRejectsAQuietProgrammeTail() async throws {
        let referenceURL = temporaryAudioURL()
        let gatedURL = temporaryAudioURL()
        defer {
            try? FileManager.default.removeItem(at: referenceURL)
            try? FileManager.default.removeItem(at: gatedURL)
        }
        try writeAudio(to: referenceURL, duration: 4, channels: 1) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }
        try writeAudio(to: gatedURL, duration: 8, channels: 1) { frame, _ in
            let amplitude = frame < Int(4 * AudioLoudnessAnalyzer.sampleRate) ? 0.1 : 0.001
            return sine(frame: frame, frequency: 1_000, amplitude: amplitude)
        }

        let reference = try await AudioLoudnessAnalyzer.analyze(from: referenceURL)
        let gated = try await AudioLoudnessAnalyzer.analyze(from: gatedURL)
        let referenceLoudness = try #require(reference.integratedLoudnessLUFS)
        let gatedLoudness = try #require(gated.integratedLoudnessLUFS)

        #expect(abs(gatedLoudness - referenceLoudness) < 0.2)
    }

    @Test func shortProgrammeStillMeasuresAndProducesActivity() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 0.25, channels: 1) { frame, _ in
            sine(frame: frame, frequency: 1_000, amplitude: 0.1)
        }

        let analysis = try await AudioLoudnessAnalyzer.analyze(from: url)
        let loudness = try #require(analysis.integratedLoudnessLUFS)
        let activity = try #require(analysis.activityRanges.first)

        #expect(abs(loudness + 23.0) < 0.12)
        #expect(analysis.activityRanges.count == 1)
        #expect(abs(activity.lowerBound) < 0.001)
        #expect(abs(activity.upperBound - 0.25) < 0.001)
    }

    @Test func activityUsesSourceTimeAndBridgesShortPauses() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 3, channels: 1) { frame, _ in
            let time = Double(frame) / AudioLoudnessAnalyzer.sampleRate
            let isActive = (1.2..<1.6).contains(time) || (1.8..<2.2).contains(time)
            return isActive ? sine(frame: frame, frequency: 1_000, amplitude: 0.1) : 0
        }

        let analysis = try await AudioLoudnessAnalyzer.analyze(from: url, range: 0.5...2.8)
        let activity = try #require(analysis.activityRanges.first)

        #expect(analysis.activityRanges.count == 1)
        // A range read must retain absolute source time, not restart at zero.
        #expect(activity.lowerBound >= 1.1 && activity.lowerBound <= 1.3)
        #expect(activity.upperBound >= 2.2 && activity.upperBound <= 2.4)
    }

    @Test func activityDiscardsAnIslandShorterThanOneHop() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 1.75, channels: 1) { frame, _ in
            let time = Double(frame) / AudioLoudnessAnalyzer.sampleRate
            let isActive = time < 1 || time >= 1.7
            return isActive ? sine(frame: frame, frequency: 1_000, amplitude: 0.1) : 0
        }

        let analysis = try await AudioLoudnessAnalyzer.analyze(from: url)

        // The 50 ms tail is isolated from the main programme and is shorter
        // than the 100 ms activity resolution, so it must not create a region.
        #expect(analysis.activityRanges.count == 1)
        #expect((analysis.activityRanges.first?.upperBound ?? 2) < 1.2)
    }

    private func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-loudness-\(UUID().uuidString).caf")
    }

    private func sine(frame: Int, frequency: Double, amplitude: Double) -> Float {
        let phase = 2 * Double.pi * frequency * Double(frame) / AudioLoudnessAnalyzer.sampleRate
        return Float(sin(phase) * amplitude)
    }

    private func writeAudio(
        to url: URL,
        duration: Double,
        channels: AVAudioChannelCount,
        sample: (Int, Int) -> Float
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: AudioLoudnessAnalyzer.sampleRate,
            channels: channels
        ) else {
            throw NSError(domain: "AudioLoudnessAnalyzerTests", code: 1)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let totalFrames = Int((duration * AudioLoudnessAnalyzer.sampleRate).rounded())
        let bufferFrames = 4_096
        var position = 0
        while position < totalFrames {
            let count = min(bufferFrames, totalFrames - position)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channelData = buffer.floatChannelData else {
                throw NSError(domain: "AudioLoudnessAnalyzerTests", code: 2)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(channels) {
                for localFrame in 0..<count {
                    channelData[channel][localFrame] = sample(position + localFrame, channel)
                }
            }
            try file.write(from: buffer)
            position += count
        }
    }
}
