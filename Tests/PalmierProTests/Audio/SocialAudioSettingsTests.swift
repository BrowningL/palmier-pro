import Foundation
import Testing
@testable import PalmierPro

@Suite("Social audio settings")
struct SocialAudioSettingsTests {
    @Test func normalizationTargetsLoudnessAndCapsPeakAndBoost() {
        #expect(SocialAudioSettings.normalizationGainDb(
            measuredLUFS: -22,
            measuredPeakDbFS: -9,
            targetLUFS: -16,
            peakCeilingDbFS: -3
        ) == 6)
        #expect(SocialAudioSettings.normalizationGainDb(
            measuredLUFS: -30,
            measuredPeakDbFS: -4,
            targetLUFS: -16,
            peakCeilingDbFS: -3
        ) == 1)
        #expect(SocialAudioSettings.normalizationGainDb(
            measuredLUFS: -40,
            measuredPeakDbFS: nil,
            targetLUFS: -16,
            peakCeilingDbFS: -3
        ) == 12)
    }

    @Test func automaticGainMultipliesAuthoredVolumeWithoutChangingIt() {
        var clip = Fixtures.clip(mediaType: .audio, start: 0, duration: 30)
        clip.volume = 0.5
        clip.socialAudio = SocialAudioSettings(role: .voice, normalizationGainDb: 6.020599913279624)

        #expect(abs(clip.volumeAt(frame: 15) - 1) < 0.000_001)
        #expect(clip.volume == 0.5)
    }

    @Test func recipeRoundTripsAndLegacyClipDefaultsToNil() throws {
        var clip = Fixtures.clip(mediaType: .audio, start: 12, duration: 90)
        clip.socialAudio = SocialAudioSettings(
            role: .voice,
            preset: .clearVoice,
            measuredLoudnessLUFS: -23.4,
            measuredPeakDbFS: -7.2,
            normalizationGainDb: 6.4,
            speechActivity: [.init(startSeconds: 0.5, endSeconds: 2.1)]
        )
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded == clip)

        let legacy = """
        {"mediaRef":"legacy","mediaType":"audio","startFrame":0,"durationFrames":30}
        """
        #expect(try JSONDecoder().decode(Clip.self, from: Data(legacy.utf8)).socialAudio == nil)
    }
}
