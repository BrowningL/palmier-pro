import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Voice cleanup")
struct VoiceCleanupTests {
    @Test func settingsClampAndClipRoundTrip() throws {
        #expect(VoiceCleanupSettings(strength: -1).strength == 0)
        #expect(VoiceCleanupSettings(strength: 2).strength == 1)

        var clip = Fixtures.clip(mediaType: .audio, start: 12, duration: 90)
        clip.voiceCleanup = VoiceCleanupSettings(strength: 0.82)
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.voiceCleanup == VoiceCleanupSettings(strength: 0.82))

        let legacy = """
        {"mediaRef":"legacy","mediaType":"audio","startFrame":0,"durationFrames":30}
        """
        let legacyClip = try JSONDecoder().decode(Clip.self, from: Data(legacy.utf8))
        #expect(legacyClip.voiceCleanup == nil)
    }

    @Test func offlineRenderPreservesLengthAndAlignmentAtZeroStrength() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-voice-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.caf")
        let outputURL = root.appendingPathComponent("clean.caf")
        let sampleRate = 48_000.0
        let frameCount = 48_000
        try writeSignal(to: sourceURL, sampleRate: sampleRate, frameCount: frameCount)

        try VoiceCleanupRenderer.render(
            sourceURL: sourceURL,
            destinationURL: outputURL,
            strength: 0
        )

        let source = try readSamples(from: sourceURL)
        let output = try readSamples(from: outputURL)
        #expect(output.count == source.count)
        let differences = zip(source, output).enumerated().map { index, pair in
            (index: index, delta: abs(pair.0 - pair.1), source: pair.0, output: pair.1)
        }
        let maximum = differences.max { $0.delta < $1.delta }
        let changed = differences.filter { $0.delta >= 0.000_01 }
        #expect(
            (maximum?.delta ?? .infinity) < 0.000_01,
            "latency-compensated dry render changed \(changed.count) samples; max=\(String(describing: maximum)) range=\(changed.first?.index ?? -1)...\(changed.last?.index ?? -1)"
        )
    }

    @Test func compositionUsesCleanedAudioProxy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-voice-composition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.caf")
        try writeSignal(to: sourceURL, sampleRate: 48_000, frameCount: 24_000)
        var clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 15)
        clip.voiceCleanup = VoiceCleanupSettings(strength: 0.75)
        let mediaRef = clip.mediaRef
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == mediaRef ? sourceURL : nil },
            renderSize: CGSize(width: timeline.width, height: timeline.height)
        )
        let audioMapping = try #require(result.trackMappings.first { !$0.isVideo })
        let segments = try await audioMapping.compositionTrack.load(.segments)
        #expect(!segments.isEmpty)

        let cleanedURL = try await VoiceCleanupCache.shared.processedURL(
            sourceURL: sourceURL,
            strength: 0.75
        )
        defer { try? FileManager.default.removeItem(at: cleanedURL) }

        #expect(cleanedURL.pathExtension == "caf")
        #expect(cleanedURL.deletingLastPathComponent().lastPathComponent == "VoiceCleanup")
    }

    @Test func truncatedCacheIsRegenerated() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-voice-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.caf")
        try writeSignal(to: sourceURL, sampleRate: 44_100, frameCount: 22_050)
        let firstURL = try await VoiceCleanupCache.shared.processedURL(
            sourceURL: sourceURL,
            strength: 0.6
        )
        defer { try? FileManager.default.removeItem(at: firstURL) }

        try Data(repeating: 0, count: 64).write(to: firstURL, options: .atomic)
        let regeneratedURL = try await VoiceCleanupCache.shared.processedURL(
            sourceURL: sourceURL,
            strength: 0.6
        )
        let regeneratedFile = try AVAudioFile(forReading: regeneratedURL)

        #expect(regeneratedURL == firstURL)
        #expect(regeneratedFile.length == 22_050)
    }

    @Test func compositionSurfacesCleanupFailureInsteadOfUsingRawAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-voice-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("broken.mov")
        try Data("not audio".utf8).write(to: sourceURL)
        var clip = Fixtures.clip(id: "broken-voice", mediaType: .audio, start: 0, duration: 15)
        clip.voiceCleanup = VoiceCleanupSettings()
        let mediaRef = clip.mediaRef
        let timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        await #expect(throws: CompositionBuilder.VoiceCleanupError.self) {
            _ = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { $0 == mediaRef ? sourceURL : nil },
                renderSize: CGSize(width: timeline.width, height: timeline.height)
            )
        }
    }

    private func writeSignal(to url: URL, sampleRate: Double, frameCount: Int) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw NSError(domain: "VoiceCleanupTests", code: 10)
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
        ) else {
            throw NSError(domain: "VoiceCleanupTests", code: 11)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let samples = buffer.floatChannelData?[0] else {
            throw NSError(domain: "VoiceCleanupTests", code: 12)
        }
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * 440 * Double(frame) / sampleRate
            samples[frame] = Float(sin(phase) * 0.2)
        }
        samples[min(10_000, frameCount - 1)] = 0.9
        try file.write(from: buffer)
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(4_096, file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: count
            ) else {
                throw NSError(domain: "VoiceCleanupTests", code: 13)
            }
            try file.read(into: buffer, frameCount: count)
            guard let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "VoiceCleanupTests", code: 14)
            }
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
        }
        return samples
    }
}

@Suite("Voice cleanup project persistence")
@MainActor
struct VoiceCleanupProjectPersistenceTests {
    @Test func projectPackageKeepsCleanupSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-voice-project-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Voice.palmier", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var clip = Fixtures.clip(id: "voice", mediaType: .audio, start: 0, duration: 60)
        clip.voiceCleanup = VoiceCleanupSettings(strength: 0.73)
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])

        try document.write(to: package, ofType: VideoProject.typeIdentifier)
        let data = try Data(contentsOf: package.appendingPathComponent(Project.timelineFilename))
        let saved = try JSONDecoder().decode(Timeline.self, from: data)
        #expect(saved.tracks.first?.clips.first?.voiceCleanup == VoiceCleanupSettings(strength: 0.73))
    }
}
