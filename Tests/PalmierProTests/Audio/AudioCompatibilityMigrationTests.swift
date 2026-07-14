import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio compatibility migration")
struct AudioCompatibilityMigrationTests {
    @Test func legacyVoiceCleanupDecodesToDenoiseAndNeverReencodes() throws {
        let json = """
        {
          "id": "voice",
          "mediaRef": "source",
          "mediaType": "audio",
          "sourceClipType": "audio",
          "startFrame": 0,
          "durationFrames": 90,
          "voiceCleanup": { "strength": 0.73 },
          "socialAudio": {
            "role": "voice",
            "preset": "clearVoice",
            "measuredLoudnessLUFS": -22.4,
            "measuredPeakDbFS": -6.2,
            "normalizationGainDb": 3.2,
            "speechActivity": [{ "startSeconds": 0.2, "endSeconds": 1.7 }],
            "duckingAmountDb": 0
          }
        }
        """

        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        let denoise = try #require(clip.effects?.first { $0.type == Clip.denoiseEffectType })
        #expect(denoise.enabled)
        #expect(denoise.params["amount"]?.value == 0.73)
        #expect(clip.socialAudio?.preset == .clearVoice)
        #expect(clip.socialAudio?.speechActivity.count == 1)

        let encoded = try JSONEncoder().encode(clip)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["voiceCleanup"] == nil)
        let roundTripped = try JSONDecoder().decode(Clip.self, from: encoded)
        #expect(roundTripped == clip)
    }

    @Test func currentDenoiseEffectWinsOverLegacyCleanupEvenWhenDisabled() throws {
        var clip = Fixtures.clip(
            id: "voice",
            mediaRef: "source",
            mediaType: .audio,
            start: 0,
            duration: 60
        )
        clip.effects = [Effect(
            type: Clip.denoiseEffectType,
            enabled: false,
            params: ["amount": EffectParam(value: 0.21)]
        )]
        let encoded = try JSONEncoder().encode(clip)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["voiceCleanup"] = ["strength": 0.94]

        let mixedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Clip.self, from: mixedData)
        let denoise = decoded.effects?.filter { $0.type == Clip.denoiseEffectType } ?? []
        #expect(denoise.count == 1)
        #expect(denoise.first?.enabled == false)
        #expect(denoise.first?.params["amount"]?.value == 0.21)
    }

    @Test func bareTimelineMigratesLegacyClipsInPlace() throws {
        let json = """
        {
          "id": "timeline",
          "name": "Legacy",
          "fps": 30,
          "width": 1080,
          "height": 1920,
          "tracks": [{
            "type": "audio",
            "clips": [{
              "id": "voice",
              "mediaRef": "source",
              "mediaType": "audio",
              "startFrame": 0,
              "durationFrames": 30,
              "voiceCleanup": { "strength": 0.6 }
            }]
          }]
        }
        """

        let project = try ProjectFile.decode(Data(json.utf8))
        let timeline = try #require(project.timelines.first)
        let clip = try #require(timeline.tracks.first?.clips.first)
        #expect(clip.hasDenoiseEnabled)
        #expect(clip.denoiseAmount == 0.6)
    }
}
