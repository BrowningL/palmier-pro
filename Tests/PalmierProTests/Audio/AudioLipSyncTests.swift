import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio presentation alignment")
struct AudioLipSyncTests {
    @Test func aacPrimingIsDecodedOnThePresentedTimelineWithoutMovingThePeak() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-audio-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.mov")
        let sampleRate = 44_100.0
        try await writeAACMovieWithPriming(to: sourceURL, sampleRate: sampleRate)

        let asset = AVURLAsset(url: sourceURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let timeRange = try await track.load(.timeRange)
        let presentedFrames = CMTimeConvertScale(
            timeRange.duration,
            timescale: CMTimeScale(sampleRate),
            method: .default
        ).value
        let containerDecode = try AVAudioFile(forReading: sourceURL)
        #expect(containerDecode.length > presentedFrames, "fixture must expose AAC priming")

        var samples: [Float] = []
        let timing = try await AudioTrackReader.read(
            from: sourceURL,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ]
        ) { buffer in
            guard let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "AudioLipSyncTests", code: 29)
            }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
        }

        #expect(samples.count == Int(presentedFrames))
        #expect(abs((timing.firstPresentationSeconds ?? .infinity) - timeRange.start.seconds) < 0.001)
        let peak = try #require(samples.indices.max { abs(samples[$0]) < abs(samples[$1]) })
        #expect(abs(peak - 10_000) <= 16)
    }

    private func writeSignal(to url: URL, sampleRate: Double, frameCount: Int) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw NSError(domain: "AudioLipSyncTests", code: 10)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let samples = buffer.floatChannelData?[0] else {
            throw NSError(domain: "AudioLipSyncTests", code: 11)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
            samples[frame] = Float(sin(phase) * 0.2)
        }
        samples[10_000] = 0.9
        try file.write(from: buffer)
    }

    private func writeAACMovieWithPriming(to url: URL, sampleRate: Double) async throws {
        let pcmURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-audio-sync-input-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: pcmURL) }
        try writeSignal(to: pcmURL, sampleRate: sampleRate, frameCount: Int(sampleRate) + 137)

        let sourceAsset = AVURLAsset(url: pcmURL)
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: sourceAsset)
        let readerOutput = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: nil)
        guard reader.canAdd(readerOutput) else {
            throw NSError(domain: "AudioLipSyncTests", code: 21)
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "AudioLipSyncTests", code: 22)
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AudioLipSyncTests", code: 23)
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AudioLipSyncTests", code: 24)
        }
        writer.startSession(atSourceTime: .zero)
        while reader.status == .reading {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw writer.error ?? NSError(domain: "AudioLipSyncTests", code: 27)
            }
            if writerInput.isReadyForMoreMediaData {
                guard let sample = readerOutput.copyNextSampleBuffer() else { break }
                guard writerInput.append(sample) else {
                    throw writer.error ?? NSError(domain: "AudioLipSyncTests", code: 25)
                }
            } else {
                await Task.yield()
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(domain: "AudioLipSyncTests", code: 28)
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "AudioLipSyncTests", code: 26)
        }
    }
}
