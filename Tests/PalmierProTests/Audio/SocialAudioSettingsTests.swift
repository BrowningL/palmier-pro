import Foundation
import Testing
@testable import PalmierPro

@Suite("Social audio settings")
struct SocialAudioSettingsTests {
    @Test func presetsDeclareTheirMusicBalanceBehavior() {
        #expect(SocialAudioPreset.balanced.displayName == "Balanced (Ducking)")
        #expect(SocialAudioPreset.balanced.musicTargetLUFS == -18)
        #expect(SocialAudioPreset.balanced.musicDuckDb == 14)
        #expect(SocialAudioPreset.balanced.usesSpeechDucking)

        #expect(SocialAudioPreset.clearVoice.displayName == "Clear Voice (Ducking)")
        #expect(SocialAudioPreset.clearVoice.musicTargetLUFS == -20)
        #expect(SocialAudioPreset.clearVoice.musicDuckDb == 18)
        #expect(SocialAudioPreset.clearVoice.usesSpeechDucking)

        #expect(SocialAudioPreset.fixedLevel.displayName == "Fixed Level (No Ducking)")
        #expect(SocialAudioPreset.fixedLevel.voiceTargetLUFS == -16)
        #expect(SocialAudioPreset.fixedLevel.musicTargetLUFS == -30)
        #expect(SocialAudioPreset.fixedLevel.musicDuckDb == 0)
        #expect(!SocialAudioPreset.fixedLevel.usesSpeechDucking)
    }

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

    @Test func fixedLevelRecipeRoundTrips() throws {
        let settings = SocialAudioSettings(
            role: .music,
            preset: .fixedLevel,
            measuredLoudnessLUFS: -13,
            measuredPeakDbFS: -1,
            normalizationGainDb: -17,
            duckingAmountDb: SocialAudioPreset.fixedLevel.musicDuckDb
        )

        let decoded = try JSONDecoder().decode(
            SocialAudioSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)
    }

    @Test func partialLegacyRecipeUsesSafeDefaults() throws {
        let data = Data(#"{"role":"music","normalizationGainDb":-8}"#.utf8)
        let settings = try JSONDecoder().decode(SocialAudioSettings.self, from: data)

        #expect(settings.role == .music)
        #expect(settings.preset == .balanced)
        #expect(settings.normalizationGainDb == -8)
        #expect(settings.speechActivity.isEmpty)
        #expect(settings.duckingAmountDb == 0)
    }
}
