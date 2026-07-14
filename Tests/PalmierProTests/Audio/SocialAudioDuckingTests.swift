import Testing
@testable import PalmierPro

@Suite("Social audio ducking")
struct SocialAudioDuckingTests {
    @Test func sourceActivityMapsThroughTrimAndSpeed() {
        let clip = Fixtures.clip(
            mediaType: .audio, start: 100, duration: 60, trimStart: 30, speed: 2
        )
        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [
                SocialAudioActivityRange(startSeconds: 0, endSeconds: 1.5),
                SocialAudioActivityRange(startSeconds: 2, endSeconds: 4),
                SocialAudioActivityRange(startSeconds: 4.5, endSeconds: 6),
            ],
            clip: clip,
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
        let clip = Fixtures.clip(
            mediaType: .audio, start: 50, duration: 10, trimStart: 30
        )
        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [SocialAudioActivityRange(startSeconds: 1.01, endSeconds: 1.09)],
            clip: clip,
            fps: 30
        )

        #expect(ranges == [SocialAudioFrameRange(startFrame: 50, endFrame: 53)])
    }

    @Test func fractionalSlowSpeedUsesRenderedSourceSpan() {
        let clip = Fixtures.clip(
            mediaType: .audio, start: 100, duration: 33, trimStart: 30, speed: 0.75
        )
        #expect(clip.renderedSourceFramesConsumed == 24)

        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [SocialAudioActivityRange(startSeconds: 53.0 / 30, endSeconds: 54.0 / 30)],
            clip: clip,
            fps: 30
        )

        // The final rendered source frame spans the final two outward-rounded timeline frames.
        #expect(ranges == [SocialAudioFrameRange(startFrame: 131, endFrame: 133)])
    }

    @Test func fractionalFastSpeedUsesRenderedSourceSpan() {
        let clip = Fixtures.clip(
            mediaType: .audio, start: 40, duration: 17, trimStart: 10, speed: 1.35
        )
        #expect(clip.renderedSourceFramesConsumed == 22)

        let ranges = SocialAudioDucking.timelineSpeechRanges(
            activity: [SocialAudioActivityRange(startSeconds: 31.0 / 30, endSeconds: 32.0 / 30)],
            clip: clip,
            fps: 30
        )

        #expect(ranges == [SocialAudioFrameRange(startFrame: 56, endFrame: 57)])
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
