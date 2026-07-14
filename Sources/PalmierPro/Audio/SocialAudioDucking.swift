import Foundation

/// A deterministic, half-open interval on the project timeline.
struct SocialAudioFrameRange: Equatable, Sendable {
    var startFrame: Int
    var endFrame: Int

    var isEmpty: Bool { endFrame <= startFrame }
    var durationFrames: Int { max(0, endFrame - startFrame) }
}

/// A sampled point in a music clip's automatic ducking envelope.
struct SocialAudioDuckingBreakpoint: Equatable, Sendable {
    /// Frame offset relative to the start of the music clip.
    var offsetFrames: Int
    var gainMultiplier: Double
}

/// A frame-domain ducking envelope suitable for AVFoundation volume ramps.
///
/// `breakpointOffsets` contains every point where the minimum of the speech
/// envelopes can change slope. `gainMultiplier(atAbsoluteFrame:)` samples that
/// same minimum, so preview and export can share identical ramp math.
struct SocialAudioDuckingPlan: Equatable, Sendable {
    let musicRange: SocialAudioFrameRange
    let breakpointOffsets: [Int]

    fileprivate let speechRanges: [SocialAudioFrameRange]
    fileprivate let duckedGain: Double
    fileprivate let attackFrames: Int
    fileprivate let releaseFrames: Int

    var breakpoints: [SocialAudioDuckingBreakpoint] {
        breakpointOffsets.map { offset in
            SocialAudioDuckingBreakpoint(
                offsetFrames: offset,
                gainMultiplier: gainMultiplier(atAbsoluteFrame: musicRange.startFrame + offset)
            )
        }
    }

    /// Samples the envelope on the closed clip-boundary domain. The music end
    /// frame is accepted because AVFoundation needs a terminal ramp value there.
    func gainMultiplier(atAbsoluteFrame frame: Int) -> Double {
        guard frame >= musicRange.startFrame, frame <= musicRange.endFrame else { return 1 }

        var gain = 1.0
        for range in speechRanges {
            gain = min(gain, gainMultiplier(for: range, at: frame))
        }
        return gain
    }

    private func gainMultiplier(for speech: SocialAudioFrameRange, at frame: Int) -> Double {
        let attackStart = speech.startFrame - attackFrames
        if frame < attackStart { return 1 }

        if frame < speech.startFrame {
            guard attackFrames > 0 else { return duckedGain }
            let progress = Double(frame - attackStart) / Double(attackFrames)
            return 1 - (1 - duckedGain) * progress
        }

        if frame <= speech.endFrame { return duckedGain }

        let releaseEnd = speech.endFrame + releaseFrames
        guard frame < releaseEnd, releaseFrames > 0 else { return 1 }
        let progress = Double(frame - speech.endFrame) / Double(releaseFrames)
        return duckedGain + (1 - duckedGain) * progress
    }
}

enum SocialAudioDucking {
    static let defaultAttackSeconds = 0.1
    static let defaultReleaseSeconds = 0.5

    /// Maps source-file speech activity onto the project timeline.
    ///
    /// Activity is first intersected with the clip's visible source interval.
    /// Mapping uses `Clip.renderedSourceFramesConsumed` and
    /// `Clip.effectivePlaybackSpeed`, matching CompositionBuilder's integer source span.
    static func timelineSpeechRanges(
        activity: [SocialAudioActivityRange],
        clip: Clip,
        fps: Int
    ) -> [SocialAudioFrameRange] {
        guard fps > 0,
              clip.durationFrames > 0,
              clip.speed.isFinite,
              clip.speed > 0
        else { return [] }

        let clipEndFrame = clip.endFrame
        let visibleSourceStart = Double(clip.trimStartFrame)
        let consumedSourceFrames = Double(clip.renderedSourceFramesConsumed)
        let visibleSourceEnd = visibleSourceStart + consumedSourceFrames
        let effectivePlaybackSpeed = clip.effectivePlaybackSpeed
        guard visibleSourceEnd > visibleSourceStart, effectivePlaybackSpeed > 0 else { return [] }

        let mapped = activity.compactMap { sourceRange -> SocialAudioFrameRange? in
            guard sourceRange.startSeconds.isFinite,
                  sourceRange.endSeconds.isFinite,
                  sourceRange.endSeconds > sourceRange.startSeconds
            else { return nil }

            let sourceStart = max(visibleSourceStart, sourceRange.startSeconds * Double(fps))
            let sourceEnd = min(visibleSourceEnd, sourceRange.endSeconds * Double(fps))
            guard sourceEnd > sourceStart else { return nil }

            let timelineStart = Double(clip.startFrame)
                + (sourceStart - visibleSourceStart) / effectivePlaybackSpeed
            let timelineEnd = Double(clip.startFrame)
                + (sourceEnd - visibleSourceStart) / effectivePlaybackSpeed
            let start = min(clipEndFrame, max(clip.startFrame, tolerantFloor(timelineStart)))
            let end = min(clipEndFrame, max(clip.startFrame, tolerantCeil(timelineEnd)))
            guard end > start else { return nil }
            return SocialAudioFrameRange(startFrame: start, endFrame: end)
        }

        return merged(ranges: mapped)
    }

    /// Unions overlapping and directly adjacent half-open ranges.
    static func merged(ranges: [SocialAudioFrameRange]) -> [SocialAudioFrameRange] {
        let sorted = ranges
            .filter { !$0.isEmpty }
            .sorted {
                if $0.startFrame == $1.startFrame { return $0.endFrame < $1.endFrame }
                return $0.startFrame < $1.startFrame
            }
        guard var current = sorted.first else { return [] }

        var result: [SocialAudioFrameRange] = []
        for next in sorted.dropFirst() {
            if next.startFrame <= current.endFrame {
                current.endFrame = max(current.endFrame, next.endFrame)
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    /// Creates a 100 ms lookahead/attack and 500 ms release envelope for one
    /// music clip. Overlapping speech envelopes resolve to the lowest gain.
    static func plan(
        musicRange: SocialAudioFrameRange,
        voiceRanges: [SocialAudioFrameRange],
        fps: Int,
        duckingAmountDb: Double,
        attackSeconds: Double = defaultAttackSeconds,
        releaseSeconds: Double = defaultReleaseSeconds
    ) -> SocialAudioDuckingPlan {
        let duration = musicRange.durationFrames
        guard fps > 0, duration > 0 else {
            return SocialAudioDuckingPlan(
                musicRange: musicRange,
                breakpointOffsets: [0],
                speechRanges: [],
                duckedGain: 1,
                attackFrames: 0,
                releaseFrames: 0
            )
        }

        let attackFrames = frameCount(seconds: attackSeconds, fps: fps)
        let releaseFrames = frameCount(seconds: releaseSeconds, fps: fps)
        let amount = duckingAmountDb.isFinite ? max(0, duckingAmountDb) : 0
        let duckedGain = pow(10, -amount / 20)

        let mergedSpeech = merged(ranges: voiceRanges).filter { speech in
            speech.startFrame - attackFrames < musicRange.endFrame
                && speech.endFrame + releaseFrames > musicRange.startFrame
        }

        guard duckedGain < 1, !mergedSpeech.isEmpty else {
            return SocialAudioDuckingPlan(
                musicRange: musicRange,
                breakpointOffsets: [0, duration],
                speechRanges: [],
                duckedGain: 1,
                attackFrames: attackFrames,
                releaseFrames: releaseFrames
            )
        }

        var absoluteBreakpoints: Set<Int> = [musicRange.startFrame, musicRange.endFrame]
        for speech in mergedSpeech {
            absoluteBreakpoints.insert(clamped(speech.startFrame - attackFrames, to: musicRange))
            absoluteBreakpoints.insert(clamped(speech.startFrame, to: musicRange))
            absoluteBreakpoints.insert(clamped(speech.endFrame, to: musicRange))
            absoluteBreakpoints.insert(clamped(speech.endFrame + releaseFrames, to: musicRange))
        }

        // In a short silence, the previous release and next lookahead overlap.
        // Their minimum changes slope where the two linear ramps cross. Keeping
        // both neighbouring integer frames preserves deterministic frame samples.
        if attackFrames > 0, releaseFrames > 0 {
            for (previous, next) in zip(mergedSpeech, mergedSpeech.dropFirst()) {
                let gap = next.startFrame - previous.endFrame
                guard gap > 0, gap < attackFrames + releaseFrames else { continue }

                let numerator = Double(attackFrames * previous.endFrame + releaseFrames * next.startFrame)
                let crossing = numerator / Double(attackFrames + releaseFrames)
                absoluteBreakpoints.insert(clamped(tolerantFloor(crossing), to: musicRange))
                absoluteBreakpoints.insert(clamped(tolerantCeil(crossing), to: musicRange))
            }
        }

        let offsets = absoluteBreakpoints
            .map { $0 - musicRange.startFrame }
            .filter { $0 >= 0 && $0 <= duration }
            .sorted()

        return SocialAudioDuckingPlan(
            musicRange: musicRange,
            breakpointOffsets: offsets,
            speechRanges: mergedSpeech,
            duckedGain: duckedGain,
            attackFrames: attackFrames,
            releaseFrames: releaseFrames
        )
    }

    private static func frameCount(seconds: Double, fps: Int) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return max(1, Int((seconds * Double(fps)).rounded()))
    }

    private static func clamped(_ frame: Int, to range: SocialAudioFrameRange) -> Int {
        min(range.endFrame, max(range.startFrame, frame))
    }

    /// Floating-point source seconds frequently land infinitesimally beside an
    /// exact frame; tolerate that noise without changing intentional fractions.
    private static func tolerantFloor(_ value: Double) -> Int {
        Int(floor(value + 1e-9))
    }

    private static func tolerantCeil(_ value: Double) -> Int {
        Int(ceil(value - 1e-9))
    }
}
