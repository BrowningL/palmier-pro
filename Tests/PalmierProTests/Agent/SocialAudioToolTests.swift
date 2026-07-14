import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — social audio")
@MainActor
struct SocialAudioToolTests {
    @Test func toolIsExposedToAgentAndMCP() {
        #expect(ToolDefinitions.inAppAgent.contains { $0.name == .balanceSocialAudio })
        #expect(ToolDefinitions.mcpServer.contains { $0.name == .balanceSocialAudio })
    }

    @Test func clearRemovesOnlyAutomaticMixSettings() async throws {
        var clip = Fixtures.clip(
            id: "audio-clip",
            mediaRef: "audio-source",
            mediaType: .audio,
            start: 0,
            duration: 30,
            volume: 0.42
        )
        clip.socialAudio = SocialAudioSettings(
            role: .music,
            normalizationGainDb: -8,
            duckingAmountDb: 14
        )
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [clip]),
        ]))

        _ = try await harness.runOK("balance_social_audio", args: [
            "action": "clear",
            "clipIds": [clip.id],
        ])

        let result = try #require(harness.editor.clipFor(id: clip.id))
        #expect(result.socialAudio == nil)
        #expect(result.volume == 0.42)
    }

    @Test func balanceAppliesRoleOverrideAndReturnsCompactRecipe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-agent-social-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("music.caf")
        try writeTone(to: audioURL)

        let clip = Fixtures.clip(
            id: "audio-clip",
            mediaRef: "audio-source",
            mediaType: .audio,
            start: 0,
            duration: 30
        )
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.audioTrack(clips: [clip]),
        ]))
        harness.editor.mediaManifest.entries = [MediaManifestEntry(
            id: clip.mediaRef,
            name: "Music",
            type: .audio,
            source: .external(absolutePath: audioURL.path),
            duration: 1
        )]

        let json = try await harness.runOK("balance_social_audio", args: [
            "preset": "fixedLevel",
            "roles": [["clipId": clip.id, "role": "music"]],
        ]) as? [String: Any]

        let result = try #require(harness.editor.clipFor(id: clip.id))
        #expect(result.socialAudio?.role == .music)
        #expect(result.socialAudio?.preset == .fixedLevel)
        #expect(result.socialAudio?.measuredLoudnessLUFS != nil)
        let returnedClip = try #require((json?["clips"] as? [[String: Any]])?.first)
        let recipe = try #require(returnedClip["socialAudio"] as? [String: Any])
        #expect(recipe["role"] as? String == "music")
        #expect(recipe["preset"] as? String == "fixedLevel")
        #expect(recipe["speechActivity"] == nil)
    }

    @Test func balanceRejectsRoleOverrideForVisualClip() async {
        let clip = Fixtures.clip(id: "visual", mediaType: .video, start: 0, duration: 30)
        let harness = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip]),
        ]))

        let result = await harness.runRaw("balance_social_audio", args: [
            "roles": [["clipId": clip.id, "role": "voice"]],
        ])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("needs audio clips"))
    }

    private func writeTone(to url: URL) throws {
        let sampleRate = AudioLoudnessAnalyzer.sampleRate
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount = Int(sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<frameCount {
            samples[frame] = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate) * 0.1)
        }
        try file.write(from: buffer)
    }
}
