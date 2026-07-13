import AVFoundation
import Testing
@testable import PalmierPro

@Suite("Social audio composition mix")
struct SocialAudioCompositionTests {
    @Test func musicDucksOnlyAcrossDetectedVoiceAndKeepsAutomaticNormalization() throws {
        let fps = 30
        var voice = Fixtures.clip(id: "voice", mediaRef: "v", mediaType: .audio, start: 0, duration: 90)
        voice.socialAudio = SocialAudioSettings(
            role: .voice,
            speechActivity: [.init(startSeconds: 1, endSeconds: 2)]
        )
        var music = Fixtures.clip(id: "music", mediaRef: "m", mediaType: .audio, start: 0, duration: 90)
        music.socialAudio = SocialAudioSettings(
            role: .music,
            normalizationGainDb: -6.020599913279624,
            duckingAmountDb: 14
        )
        let timeline = Fixtures.timeline(fps: fps, tracks: [
            Fixtures.audioTrack(clips: [voice]),
            Fixtures.audioTrack(clips: [music]),
        ])

        let composition = AVMutableComposition()
        let voiceTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let musicTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let mappings = [
            mapping(track: voiceTrack, trackIndex: 0, clipId: voice.id),
            mapping(track: musicTrack, trackIndex: 1, clipId: music.id),
        ]

        let mix = CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: mappings,
            compositionDuration: CMTime(value: 90, timescale: 30),
            renderSize: CGSize(width: 1080, height: 1920)
        ).audioMix
        let params = try #require(mix.inputParameters.first { $0.trackID == musicTrack.trackID })

        let before = try #require(volumeRamp(params, atFrame: 10, fps: fps))
        #expect(abs(before.start - 0.5) < 0.000_1)
        #expect(abs(before.end - 0.5) < 0.000_1)

        let attack = try #require(volumeRamp(params, atFrame: 28, fps: fps))
        #expect(abs(attack.start - 0.5) < 0.000_1)
        #expect(abs(attack.end - Float(0.5 * pow(10, -14.0 / 20))) < 0.000_1)
        #expect(attack.range.start == CMTime(value: 27, timescale: 30))
        #expect(attack.range.end == CMTime(value: 30, timescale: 30))

        let underVoice = try #require(volumeRamp(params, atFrame: 45, fps: fps))
        let expectedDucked = Float(0.5 * pow(10, -14.0 / 20))
        #expect(abs(underVoice.start - expectedDucked) < 0.000_1)
        #expect(abs(underVoice.end - expectedDucked) < 0.000_1)

        let afterRelease = try #require(volumeRamp(params, atFrame: 80, fps: fps))
        #expect(abs(afterRelease.start - 0.5) < 0.000_1)
        #expect(abs(afterRelease.end - 0.5) < 0.000_1)
    }

    @Test func fixedLevelMusicStaysConstantAcrossDetectedVoice() throws {
        let fps = 30
        let preset = SocialAudioPreset.fixedLevel
        var voice = Fixtures.clip(id: "voice", mediaRef: "v", mediaType: .audio, start: 0, duration: 90)
        voice.socialAudio = SocialAudioSettings(
            role: .voice,
            preset: preset,
            speechActivity: [.init(startSeconds: 1, endSeconds: 2)]
        )
        var music = Fixtures.clip(id: "music", mediaRef: "m", mediaType: .audio, start: 0, duration: 90)
        music.socialAudio = SocialAudioSettings(
            role: .music,
            preset: preset,
            normalizationGainDb: -6.020599913279624,
            duckingAmountDb: preset.musicDuckDb
        )
        let timeline = Fixtures.timeline(fps: fps, tracks: [
            Fixtures.audioTrack(clips: [voice]),
            Fixtures.audioTrack(clips: [music]),
        ])

        let composition = AVMutableComposition()
        let voiceTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let musicTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let mix = CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: [
                mapping(track: voiceTrack, trackIndex: 0, clipId: voice.id),
                mapping(track: musicTrack, trackIndex: 1, clipId: music.id),
            ],
            compositionDuration: CMTime(value: 90, timescale: 30),
            renderSize: CGSize(width: 1080, height: 1920)
        ).audioMix
        let params = try #require(mix.inputParameters.first { $0.trackID == musicTrack.trackID })

        for frame in [10, 45, 80] {
            let ramp = try #require(volumeRamp(params, atFrame: frame, fps: fps))
            #expect(abs(ramp.start - 0.5) < 0.000_1)
            #expect(abs(ramp.end - 0.5) < 0.000_1)
        }
    }

    @Test func mutedVoiceTrackDoesNotDuckMusic() throws {
        var voice = Fixtures.clip(id: "voice", mediaRef: "v", mediaType: .audio, start: 0, duration: 60)
        voice.socialAudio = SocialAudioSettings(
            role: .voice,
            speechActivity: [.init(startSeconds: 0, endSeconds: 2)]
        )
        var music = Fixtures.clip(id: "music", mediaRef: "m", mediaType: .audio, start: 0, duration: 60)
        music.socialAudio = SocialAudioSettings(role: .music, duckingAmountDb: 14)
        var voiceTrackModel = Fixtures.audioTrack(clips: [voice])
        voiceTrackModel.muted = true
        let timeline = Fixtures.timeline(fps: 30, tracks: [
            voiceTrackModel,
            Fixtures.audioTrack(clips: [music]),
        ])

        let composition = AVMutableComposition()
        let voiceTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let musicTrack = try #require(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let mix = CompositionBuilder.buildVisuals(
            timeline: timeline,
            trackMappings: [
                mapping(track: voiceTrack, trackIndex: 0, clipId: voice.id),
                mapping(track: musicTrack, trackIndex: 1, clipId: music.id),
            ],
            compositionDuration: CMTime(value: 60, timescale: 30),
            renderSize: CGSize(width: 1080, height: 1920)
        ).audioMix
        let params = try #require(mix.inputParameters.first { $0.trackID == musicTrack.trackID })
        let ramp = try #require(volumeRamp(params, atFrame: 30, fps: 30))
        #expect(ramp.start == 1)
        #expect(ramp.end == 1)
    }

    private func mapping(
        track: AVMutableCompositionTrack,
        trackIndex: Int,
        clipId: String
    ) -> TrackMapping {
        TrackMapping(
            compositionTrack: track,
            kind: .timeline(trackIndex: trackIndex, clipIds: [clipId]),
            naturalSize: .zero,
            endTime: .zero,
            isVideo: false
        )
    }

    private func volumeRamp(
        _ params: AVAudioMixInputParameters,
        atFrame frame: Int,
        fps: Int
    ) -> (start: Float, end: Float, range: CMTimeRange)? {
        var start: Float = -1
        var end: Float = -1
        var range = CMTimeRange()
        let found = params.getVolumeRamp(
            for: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)),
            startVolume: &start,
            endVolume: &end,
            timeRange: &range
        )
        return found ? (start, end, range) : nil
    }
}
