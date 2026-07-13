import Testing
@testable import PalmierPro

@Suite("ToolExecutor — voice cleanup")
@MainActor
struct VoiceCleanupToolTests {
    @Test func setClipPropertiesControlsAudioCleanup() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .audio)
        let asset = h.addAsset(type: .audio)
        let clipId = try #require(
            h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60).first
        )

        let enabled = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId],
            "voiceCleanupEnabled": true,
            "voiceCleanupStrength": 0.85,
        ])
        #expect(enabled.isError == false, "\(ToolHarness.textOf(enabled))")
        #expect(h.editor.clipFor(id: clipId)?.voiceCleanup == VoiceCleanupSettings(strength: 0.85))

        let disabled = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId],
            "voiceCleanupEnabled": false,
        ])
        #expect(disabled.isError == false, "\(ToolHarness.textOf(disabled))")
        #expect(h.editor.clipFor(id: clipId)?.voiceCleanup == nil)
    }

    @Test func cleanupRejectsVisualClipsAndInvalidStrength() async throws {
        let h = ToolHarness()
        _ = h.editor.insertTrack(at: 0, type: .video)
        let asset = h.addAsset(type: .video)
        let clipId = try #require(
            h.editor.placeClip(asset: asset, trackIndex: 0, startFrame: 0, durationFrames: 60).first
        )

        let visual = await h.runRaw("set_clip_properties", args: [
            "clipIds": [clipId],
            "voiceCleanupEnabled": true,
        ])
        #expect(visual.isError)

        var audio = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 60)
        audio.sourceClipType = .audio
        h.editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [audio])])
        let invalid = await h.runRaw("set_clip_properties", args: [
            "clipIds": ["audio"],
            "voiceCleanupStrength": 1.2,
        ])
        #expect(invalid.isError)
    }
}
