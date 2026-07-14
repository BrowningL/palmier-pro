import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio beat detector")
struct AudioBeatDetectorTests {
    @Test func detectsSynthetic120BPMGridWithCalibratedTiming() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 10, bpm: 120, phase: 0.23)

        let analysis = try await AudioBeatDetector.analyze(from: url)

        #expect(abs(analysis.tempoBPM - 120) < 3)
        #expect(analysis.confidence >= 0.45)
        let expected = stride(from: 0.23, through: 9.73, by: 0.5).map { $0 }
        let errors = expected.compactMap { time -> Double? in
            analysis.beats.map { abs($0.sourceSeconds - time) }.min()
        }.sorted()
        let medianError = try #require(errors[safe: errors.count / 2])
        #expect(medianError <= AudioBeatDetector.hopSeconds * 2.5)
        let tolerance = AudioBeatDetector.hopSeconds * 3
        let recalled = expected.count(where: { time in
            analysis.beats.contains { abs($0.sourceSeconds - time) <= tolerance }
        })
        let precise = analysis.beats.count(where: { beat in
            expected.contains { abs($0 - beat.sourceSeconds) <= tolerance }
        })
        #expect(Double(recalled) / Double(expected.count) >= 0.9)
        #expect(Double(precise) / Double(max(1, analysis.beats.count)) >= 0.9)
    }

    @Test func rangePrerollRejectsTrimBoundaryButKeepsARealBoundaryBeat() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 12, bpm: 120, phase: 0.2)

        let betweenBeats = try await AudioBeatDetector.analyze(
            from: url,
            range: 2.45...8.45,
            bpmOverride: 120
        )
        #expect(!betweenBeats.beats.contains {
            abs($0.sourceSeconds - 2.45) <= AudioBeatDetector.hopSeconds * 2
        })
        let nextBeat = try #require(betweenBeats.beats.map { abs($0.sourceSeconds - 2.7) }.min())
        #expect(nextBeat <= AudioBeatDetector.hopSeconds * 2.5)

        let justAfterBeat = try await AudioBeatDetector.analyze(
            from: url,
            range: 2.72...8.72,
            bpmOverride: 120
        )
        #expect(!justAfterBeat.beats.contains {
            abs($0.sourceSeconds - 2.72) <= AudioBeatDetector.hopSeconds
        })
        let firstAudibleBeat = try #require(
            justAfterBeat.beats.map { abs($0.sourceSeconds - 3.2) }.min()
        )
        #expect(firstAudibleBeat <= AudioBeatDetector.hopSeconds * 2.5)

        let onBeat = try await AudioBeatDetector.analyze(
            from: url,
            range: 2.2...8.2,
            bpmOverride: 120
        )
        let boundaryBeat = try #require(onBeat.beats.map { abs($0.sourceSeconds - 2.2) }.min())
        #expect(boundaryBeat <= AudioBeatDetector.hopSeconds * 2.5)
    }

    @Test func lowTempoOverrideKeepsEnoughPrerollForABoundaryBeat() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 14, bpm: 30, phase: 0.2)

        let analysis = try await AudioBeatDetector.analyze(
            from: url,
            range: 4.2...12.2,
            bpmOverride: 30
        )
        let boundaryBeat = try #require(analysis.beats.map { abs($0.sourceSeconds - 4.2) }.min())
        #expect(boundaryBeat <= AudioBeatDetector.hopSeconds * 2.5)
    }

    @Test func overrideOutsideDefaultSearchRangeUsesItsActualPeriod() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 8, bpm: 240, phase: 0.17)

        let analysis = try await AudioBeatDetector.analyze(from: url, bpmOverride: 240)
        #expect(analysis.tempoBPM == 240)
        let intervals = zip(analysis.beats.dropFirst(), analysis.beats).map {
            $0.0.sourceSeconds - $0.1.sourceSeconds
        }
        let medianInterval = try #require(intervals.sorted()[safe: intervals.count / 2])
        #expect(abs(medianInterval - 0.25) <= AudioBeatDetector.hopSeconds * 2)
    }

    @Test func aMissingOnsetDoesNotBreakTheGridPhase() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(
            to: url,
            duration: 10,
            bpm: 120,
            phase: 0.23,
            missingBeatIndices: [8]
        )

        let analysis = try await AudioBeatDetector.analyze(from: url, bpmOverride: 120)
        let missingBeatTime = 0.23 + 8 * 0.5
        let nearest = try #require(analysis.beats.map { abs($0.sourceSeconds - missingBeatTime) }.min())
        #expect(nearest <= AudioBeatDetector.hopSeconds * 3)
    }

    @Test func sourceRangeKeepsAbsoluteTimesAndVisibleBeatPhase() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 12, bpm: 120, phase: 0.2)

        let analysis = try await AudioBeatDetector.analyze(from: url, range: 2.0...8.0)

        #expect(analysis.beats.allSatisfy { $0.sourceSeconds >= 2 && $0.sourceSeconds <= 8 })
        let nearest = try #require(analysis.beats.map { abs($0.sourceSeconds - 2.2) }.min())
        #expect(nearest <= AudioBeatDetector.hopSeconds * 2.5)
    }

    @Test func BPMOverrideResolvesHalfDoubleChoiceWithoutChangingPhase() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 10, bpm: 90, phase: 0.31, addEighthNotes: true)

        let analysis = try await AudioBeatDetector.analyze(
            from: url,
            tempoRange: 60...200,
            bpmOverride: 90
        )

        #expect(analysis.tempoBPM == 90)
        let nearest = try #require(analysis.beats.map { abs($0.sourceSeconds - 0.31) }.min())
        #expect(nearest < 0.06)
    }

    @Test func silenceDoesNotFabricateBeatMarkers() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 5) { _ in 0 }

        await #expect(throws: AudioBeatDetectorError.self) {
            _ = try await AudioBeatDetector.analyze(from: url)
        }
    }

    @Test func steadyToneDoesNotFabricateARepeatingBeat() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeAudio(to: url, duration: 6) { frame in
            let time = Double(frame) / AudioBeatDetector.sampleRate
            return Float(0.25 * sin(2 * .pi * 440 * time))
        }

        await #expect(throws: AudioBeatDetectorError.self) {
            _ = try await AudioBeatDetector.analyze(from: url)
        }
    }

    @Test func resamplesStereoNonDefaultRateWithoutLosingBeatTiming() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeStereoRhythm(to: url, duration: 8, bpm: 120, phase: 0.21)

        let analysis = try await AudioBeatDetector.analyze(from: url, bpmOverride: 120)
        let nearest = try #require(analysis.beats.map { abs($0.sourceSeconds - 4.21) }.min())
        #expect(nearest <= AudioBeatDetector.hopSeconds * 3)
    }

    @Test func AACPrimingAndEditListKeepPresentationBeatTiming() async throws {
        let pcmURL = temporaryAudioURL()
        let movieURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-beats-aac-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            try? FileManager.default.removeItem(at: movieURL)
        }
        try writeRhythm(to: pcmURL, duration: 8, bpm: 120, phase: 0.21)
        try await transcodeToAACMovie(from: pcmURL, to: movieURL)

        let analysis = try await AudioBeatDetector.analyze(from: movieURL, bpmOverride: 120)
        let nearest = try #require(analysis.beats.map { abs($0.sourceSeconds - 4.21) }.min())
        #expect(nearest <= AudioBeatDetector.hopSeconds * 3)

        let subrange = try await AudioBeatDetector.analyze(
            from: movieURL,
            range: 2.46...6.46,
            bpmOverride: 120
        )
        #expect(subrange.beats.allSatisfy { (2.46...6.46).contains($0.sourceSeconds) })
        let firstAudible = try #require(subrange.beats.map { abs($0.sourceSeconds - 2.71) }.min())
        #expect(firstAudible <= AudioBeatDetector.hopSeconds * 3)
    }

    @Test func analysisShorterThanThreeSecondsIsRejected() async throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 4, bpm: 120, phase: 0)

        await #expect(throws: AudioBeatDetectorError.self) {
            _ = try await AudioBeatDetector.analyze(from: url, range: 0...2.5)
        }
    }

    private func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-beats-\(UUID().uuidString).caf")
    }

    private func writeRhythm(
        to url: URL,
        duration: Double,
        bpm: Double,
        phase: Double,
        addEighthNotes: Bool = false,
        missingBeatIndices: Set<Int> = []
    ) throws {
        let period = 60 / bpm
        try writeAudio(to: url, duration: duration) { frame in
            let time = Double(frame) / AudioBeatDetector.sampleRate
            func pulse(period: Double, amplitude: Double) -> Double {
                let shifted = time - phase
                guard shifted >= 0 else { return 0 }
                let beatIndex = Int(floor(shifted / period + 1e-9))
                guard !missingBeatIndices.contains(beatIndex) else { return 0 }
                let local = shifted.truncatingRemainder(dividingBy: period)
                guard local < 0.045 else { return 0 }
                let decay = exp(-local * 75)
                let kick = sin(2 * .pi * 85 * local)
                let attack = sin(2 * .pi * 2_100 * local)
                return amplitude * decay * (0.72 * kick + 0.28 * attack)
            }
            let beat = pulse(period: period, amplitude: 0.75)
            let eighth = addEighthNotes ? pulse(period: period / 2, amplitude: 0.16) : 0
            let bed = 0.015 * sin(2 * .pi * 330 * time)
            return Float(max(-1, min(1, beat + eighth + bed)))
        }
    }

    private func writeAudio(
        to url: URL,
        duration: Double,
        sample: (Int) -> Float
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: AudioBeatDetector.sampleRate,
            channels: 1
        ) else {
            throw NSError(domain: "AudioBeatDetectorTests", code: 1)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = Int((duration * AudioBeatDetector.sampleRate).rounded())
        var position = 0
        while position < totalFrames {
            let count = min(4_096, totalFrames - position)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "AudioBeatDetectorTests", code: 2)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { channel[index] = sample(position + index) }
            try file.write(from: buffer)
            position += count
        }
    }

    private func transcodeToAACMovie(from sourceURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioBeatDetectorTests", code: 10)
        }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(readerOutput) else {
            throw NSError(domain: "AudioBeatDetectorTests", code: 11)
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "AudioBeatDetectorTests", code: 12)
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AudioBeatDetectorTests", code: 13)
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AudioBeatDetectorTests", code: 14)
        }
        writer.startSession(atSourceTime: .zero)
        while reader.status == .reading {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? NSError(domain: "AudioBeatDetectorTests", code: 15)
            }
            if writerInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                guard writerInput.append(sample) else {
                    throw writer.error ?? NSError(domain: "AudioBeatDetectorTests", code: 16)
                }
            } else {
                await Task.yield()
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(domain: "AudioBeatDetectorTests", code: 17)
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "AudioBeatDetectorTests", code: 18)
        }
    }

    private func writeStereoRhythm(
        to url: URL,
        duration: Double,
        bpm: Double,
        phase: Double
    ) throws {
        let sourceRate = 44_100.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sourceRate,
            channels: 2
        ) else { throw NSError(domain: "AudioBeatDetectorTests", code: 3) }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let totalFrames = Int((duration * sourceRate).rounded())
        let period = 60 / bpm
        var position = 0
        while position < totalFrames {
            let count = min(4_096, totalFrames - position)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channels = buffer.floatChannelData else {
                throw NSError(domain: "AudioBeatDetectorTests", code: 4)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let time = Double(position + index) / sourceRate
                let shifted = time - phase
                let local = shifted >= 0 ? shifted.truncatingRemainder(dividingBy: period) : period
                let envelope = local < 0.045 ? exp(-local * 75) : 0
                channels[0][index] = Float(envelope * sin(2 * .pi * 90 * local) * 0.8)
                channels[1][index] = Float(envelope * sin(2 * .pi * 1_800 * local) * 0.55)
            }
            try file.write(from: buffer)
            position += count
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
