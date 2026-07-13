import Testing
@testable import PalmierPro

@Suite("Social audio ducking")
struct SocialAudioDuckingTests {
    @Test func sourceActivityMapsThroughTrimAndSpeed() {
        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [
                SocialAudioActivityRange(startSeconds: 0, endSeconds: 1.5),
                SocialAudioActivityRange(startSeconds: 2, endSeconds: 4),
                SocialAudioActivityRange(startSeconds: 4.5, endSeconds: 6),
            ],
            clipStartFrame: 100,
            clipDurationFrames: 60,
            trimStartFrame: 30,
            speed: 2,
            fps: 30
        )

        // Visible source is [1s, 5s), mapped at 2x into timeline [100, 160).
        #expect(ranges == [
            SocialAudioFrameRange(startFrame: 100, endFrame: 108),
            SocialAudioFrameRange(startFrame: 115, endFrame: 145),
            SocialAudioFrameRange(startFrame: 152, endFrame: 160),
        ])
    }

    @Test func sourceActivityRoundsOutwardAndClampsToVisibleClip() {
        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [SocialAudioActivityRange(startSeconds: 1.01, endSeconds: 1.09)],
            clipStartFrame: 50,
            clipDurationFrames: 10,
            trimStartFrame: 30,
            speed: 1,
            fps: 30
        )

        #expect(ranges == [SocialAudioFrameRange(startFrame: 50, endFrame: 53)])
    }

    @Test func mergingUnionsOverlapAndAdjacency() {
        let ranges = SocialAudioDucking.merged(ranges: [
            SocialAudioFrameRange(startFrame: 30, endFrame: 40),
            SocialAudioFrameRange(startFrame: 10, endFrame: 20),
            SocialAudioFrameRange(startFrame: 18, endFrame: 25),
            SocialAudioFrameRange(startFrame: 25, endFrame: 28),
            SocialAudioFrameRange(startFrame: 50, endFrame: 50),
        ])

        #expect(ranges == [
            SocialAudioFrameRange(startFrame: 10, endFrame: 28),
            SocialAudioFrameRange(startFrame: 30, endFrame: 40),
        ])
    }

    @Test func planUsesPhoneFriendlyAttackAndRelease() throws {
        let plan = SocialAudioDucking.plan(
            musicRange: SocialAudioFrameRange(startFrame: 100, endFrame: 200),
            voiceRanges: [SocialAudioFrameRange(startFrame: 120, endFrame: 150)],
            fps: 30,
            duckingAmountDb: 12.041_199_826_559_248
        )

        #expect(plan.breakpointOffsets == [0, 17, 20, 50, 65, 100])
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 117) - 1) < 0.0001)
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 120) - 0.25) < 0.0001)
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 150) - 0.25) < 0.0001)
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 165) - 1) < 0.0001)
    }

    @Test func overlappingReleaseAndLookaheadUseStrongestGain() {
        let plan = SocialAudioDucking.plan(
            musicRange: SocialAudioFrameRange(startFrame: 100, endFrame: 200),
            voiceRanges: [
                SocialAudioFrameRange(startFrame: 120, endFrame: 130),
                SocialAudioFrameRange(startFrame: 135, endFrame: 145),
            ],
            fps: 30,
            duckingAmountDb: 12.041_199_826_559_248
        )

        // Crossing is at frame 134.166..., so both surrounding frame samples
        // are slope boundaries for a frame-domain volume ramp.
        #expect(plan.breakpointOffsets.contains(34))
        #expect(plan.breakpointOffsets.contains(35))
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 134) - 0.45) < 0.0001)
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 135) - 0.25) < 0.0001)
    }

    @Test func envelopeIsClampedToMusicBoundaries() {
        let plan = SocialAudioDucking.plan(
            musicRange: SocialAudioFrameRange(startFrame: 100, endFrame: 110),
            voiceRanges: [SocialAudioFrameRange(startFrame: 80, endFrame: 98)],
            fps: 10,
            duckingAmountDb: 12.041_199_826_559_248
        )

        #expect(plan.breakpointOffsets == [0, 3, 10])
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 100) - 0.55) < 0.0001)
        #expect(abs(plan.gainMultiplier(atAbsoluteFrame: 103) - 1) < 0.0001)
        #expect(plan.gainMultiplier(atAbsoluteFrame: 99) == 1)
        #expect(plan.gainMultiplier(atAbsoluteFrame: 111) == 1)
    }
}
