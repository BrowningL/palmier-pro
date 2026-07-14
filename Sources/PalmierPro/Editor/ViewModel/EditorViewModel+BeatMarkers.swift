import Foundation

extension EditorViewModel {
    private struct SourceBeat {
        let index: Int
        let sourceSeconds: Double
        let isDownbeat: Bool
    }

    struct TimelineBeat: Sendable, Equatable {
        let index: Int
        let frame: Int
        let isDownbeat: Bool
        let sourceSeconds: Double
    }

    struct BeatMarkerReport: Sendable {
        let sourceClipId: String
        let sourceTempoBPM: Double
        let timelineTempoBPM: Double
        let everyNthBeat: Int
        let detectedBeatCount: Int
        let beats: [TimelineBeat]
        let markers: [TimelineMarker]
    }

    enum BeatMarkerError: LocalizedError {
        case clipNotFound
        case noAudio
        case invalidSelection
        case clipChanged
        case superseded
        case tooManyMarkers(Int)
        case noVisibleBeats

        var errorDescription: String? {
            switch self {
            case .clipNotFound: "The source clip is no longer on the active timeline."
            case .noAudio: "The selected clip has no audio track to analyse."
            case .invalidSelection: "Beat spacing and offset must select at least one beat."
            case .clipChanged: "The audio clip changed while its beats were being analysed. Run detection again."
            case .superseded: "A newer beat-marker request replaced this one."
            case .tooManyMarkers(let count):
                "This would add \(count) beat markers. Choose every 2 or every 4 beats to keep the timeline responsive."
            case .noVisibleBeats: "No detected beats fall inside the visible part of this clip."
            }
        }
    }

    func canDetectBeats(clipId: String) -> Bool {
        guard let sourceId = canonicalBeatSourceClipId(for: clipId),
              let clip = clipFor(id: sourceId),
              let asset = mediaAssetsById[clip.mediaRef] else { return false }
        return clip.mediaType == .audio || asset.hasAudio
    }

    /// Linked video/audio pairs share one persistent grid on the audio-bearing partner.
    func canonicalBeatSourceClipId(for clipId: String) -> String? {
        guard let clip = clipFor(id: clipId) else { return nil }
        if clip.mediaType == .video {
            for partnerId in linkedPartnerIds(of: clipId) where clipFor(id: partnerId)?.mediaType == .audio {
                return partnerId
            }
        }
        return clipId
    }

    @discardableResult
    func addBeatMarkers(
        clipId: String,
        everyNthBeat: Int = 1,
        beatOffset: Int = 0,
        downbeatsOnly: Bool = false,
        forceDetection: Bool = false,
        color: String? = "#58A822"
    ) async throws -> BeatMarkerReport {
        guard (1...16).contains(everyNthBeat), (0..<everyNthBeat).contains(beatOffset) else {
            throw BeatMarkerError.invalidSelection
        }
        guard let sourceClipId = canonicalBeatSourceClipId(for: clipId),
              let sourceClip = clipFor(id: sourceClipId),
              let asset = mediaAssetsById[sourceClip.mediaRef],
              sourceClip.mediaType == .audio || asset.hasAudio else {
            throw BeatMarkerError.noAudio
        }

        let timelineId = activeTimelineId
        let timingSignature = sourceClip.beatMarkerTimingSignature(fps: timeline.fps)
        let requestId = UUID()
        beatMarkerRequestIds[sourceClipId] = requestId
        defer {
            if beatMarkerRequestIds[sourceClipId] == requestId {
                beatMarkerRequestIds.removeValue(forKey: sourceClipId)
            }
        }

        let analysis = try await mediaVisualCache.beats.detect(for: asset, force: forceDetection).value
        try Task.checkCancellation()
        guard activeTimelineId == timelineId,
              beatMarkerRequestIds[sourceClipId] == requestId else { throw BeatMarkerError.superseded }
        guard let currentClip = clipFor(id: sourceClipId),
              currentClip.beatMarkerTimingSignature(fps: timeline.fps) == timingSignature else {
            throw BeatMarkerError.clipChanged
        }

        let fps = timeline.fps
        let sourceBeats = Self.mergedSourceBeats(analysis)
        let cadencePool = downbeatsOnly ? sourceBeats.filter(\.isDownbeat) : sourceBeats
        let beats = Self.projectedBeats(cadencePool, through: currentClip, fps: fps)
        guard !beats.isEmpty else { throw BeatMarkerError.noVisibleBeats }

        // Select in source time before clipping to the visible range. A trim must
        // not reset the musical phase of "every 2/every 4" grids.
        let selectedSourceBeats = cadencePool.enumerated().compactMap { offset, beat in
            offset % everyNthBeat == beatOffset ? beat : nil
        }
        let selected = Self.projectedBeats(selectedSourceBeats, through: currentClip, fps: fps)
        guard !selected.isEmpty else { throw BeatMarkerError.noVisibleBeats }
        guard selected.count <= 2_000 else { throw BeatMarkerError.tooManyMarkers(selected.count) }
        guard beatMarkerRequestIds[sourceClipId] == requestId,
              currentClip.beatMarkerTimingSignature(fps: timeline.fps) == timingSignature else {
            throw BeatMarkerError.superseded
        }
        let markers = replaceGeneratedBeatMarkers(
            sourceClipId: sourceClipId,
            drafts: selected.map {
                BeatMarkerDraft(
                    frame: $0.frame,
                    beatIndex: $0.index,
                    isDownbeat: $0.isDownbeat,
                    sourceSeconds: $0.sourceSeconds
                )
            },
            color: color
        )

        return BeatMarkerReport(
            sourceClipId: sourceClipId,
            sourceTempoBPM: analysis.bpm,
            timelineTempoBPM: analysis.bpm * currentClip.effectivePlaybackSpeed,
            everyNthBeat: everyNthBeat,
            detectedBeatCount: beats.count,
            beats: beats,
            markers: markers
        )
    }

    /// Beat This emits beats and downbeats independently. Merge close pairs in
    /// source time before frame projection so a normal detector offset does not
    /// create double cuts. Indices are assigned across the complete source media,
    /// then survive clip trims and project-frame collisions.
    private static func mergedSourceBeats(_ analysis: BeatAnalysis) -> [SourceBeat] {
        let tolerance = 0.03
        let beats = analysis.beats.filter { $0.isFinite && $0 >= 0 }.sorted()
        let downbeats = analysis.downbeats.filter { $0.isFinite && $0 >= 0 }.sorted()
        var merged: [(seconds: Double, isDownbeat: Bool)] = []
        var beatIndex = 0

        for downbeat in downbeats {
            while beatIndex < beats.count, beats[beatIndex] < downbeat - tolerance {
                merged.append((beats[beatIndex], false))
                beatIndex += 1
            }
            if beatIndex < beats.count, abs(beats[beatIndex] - downbeat) <= tolerance {
                beatIndex += 1
            }
            merged.append((downbeat, true))
        }
        while beatIndex < beats.count {
            merged.append((beats[beatIndex], false))
            beatIndex += 1
        }

        return merged.enumerated().map { offset, beat in
            SourceBeat(index: offset + 1, sourceSeconds: beat.seconds, isDownbeat: beat.isDownbeat)
        }
    }

    private static func projectedBeats(_ beats: [SourceBeat], through clip: Clip, fps: Int) -> [TimelineBeat] {
        var byFrame: [Int: TimelineBeat] = [:]
        for beat in beats {
            guard let frame = clip.timelineFrame(sourceSeconds: beat.sourceSeconds, fps: fps) else { continue }
            let projected = TimelineBeat(
                index: beat.index,
                frame: frame,
                isDownbeat: beat.isDownbeat,
                sourceSeconds: beat.sourceSeconds
            )
            if let current = byFrame[frame] {
                if projected.isDownbeat && !current.isDownbeat {
                    byFrame[frame] = projected
                } else if projected.isDownbeat == current.isDownbeat, projected.index < current.index {
                    byFrame[frame] = projected
                }
            } else {
                byFrame[frame] = projected
            }
        }
        return byFrame.keys.sorted().compactMap { byFrame[$0] }
    }
}
