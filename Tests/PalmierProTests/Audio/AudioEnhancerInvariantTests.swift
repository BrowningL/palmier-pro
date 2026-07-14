import Testing
@testable import PalmierPro

@Suite("Audio enhancer alignment invariants")
struct AudioEnhancerInvariantTests {
    @Test func wetChannelsAreTrimmedOrPaddedToDecodedDryLength() throws {
        let aligned = try AudioEnhancer.alignedWetChannels(
            [[1, 2, 3, 4], [5]],
            dryFrameCounts: [3, 3]
        )

        #expect(aligned[0] == [1, 2, 3])
        #expect(aligned[1] == [5, 0, 0])
    }

    @Test func channelLayoutMismatchFailsInsteadOfWritingMisalignedAudio() {
        #expect(throws: AudioEnhancer.EnhanceError.self) {
            _ = try AudioEnhancer.alignedWetChannels(
                [[1, 2]],
                dryFrameCounts: [2, 2]
            )
        }
    }

    @Test func cacheFrameCountIncludesPresentationLeadingSilenceExactlyOnce() {
        #expect(AudioEnhancer.expectedOutputFrameCount(
            decodedFrameCount: 44_237,
            leadingSilenceFrames: 1_024
        ) == 45_261)
        #expect(AudioEnhancer.expectedOutputFrameCount(
            decodedFrameCount: 44_237,
            leadingSilenceFrames: 0
        ) == 44_237)
    }
}
