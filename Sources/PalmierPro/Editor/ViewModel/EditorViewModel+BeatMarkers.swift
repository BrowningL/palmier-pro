import Foundation

extension EditorViewModel {
    struct TimelineBeat: Sendable, Equatable {
        let index: Int
        let frame: Int
        let strength: Double
    }

    struct BeatDetectionReport: Sendable {
        let sourceClipId: String
        let sourceTempoBPM: Double
        let timelineTempoBPM: Double
        let confidence: Double
        let clipStartFrame: Int
        let clipDurationFrames: Int
        let clipTrimStartFrame: Int
        let clipSpeed: Double
        let beats: [TimelineBeat]
    }

    struct BeatMarkerReport: Sendable {
        let sourceClipId: String
        let sourceTempoBPM: Double
        let timelineTempoBPM: Double
        let confidence: Double
        let everyNthBeat: Int
        let detectedBeatCount: Int
        let beats: [TimelineBeat]
        let markers: [TimelineMarker]
    }

    enum BeatMarkerError: LocalizedError {
        case clipNotFound
        case noAudio
        case mediaOffline
        case invalidSelection
        case clipChanged
        case superseded
        case lowConfidence(Double)
        case tooManyMarkers(Int)
        case noVisibleBeats

        var errorDescription: String? {
            switch self {
            case .clipNotFound:
                "The source clip is no longer on the timeline."
            case .noAudio:
                "The selected clip has no audio track to analyse."
            case .mediaOffline:
                "The selected clip's source media is offline."
            case .invalidSelection:
                "Beat spacing and offset must select at least one beat."
            case .clipChanged:
                "The audio clip changed while its beats were being analysed. Run beat detection again."
            case .superseded:
                "A newer beat-marker request replaced this one."
            case .lowConfidence(let confidence):
                "Beat confidence is only \(Int((confidence * 100).rounded()))%. Try a more rhythmic section, provide its BPM, or explicitly allow low-confidence markers."
            case .tooManyMarkers(let count):
                "This would add \(count) beat markers. Choose every 2 or every 4 beats to keep the timeline responsive."
            case .noVisibleBeats:
                "No detected beats fall inside the visible part of this clip."
            }
        }
    }

    private struct BeatClipTiming: Sendable, Equatable {
        let mediaRef: String
        let startFrame: Int
        let durationFrames: Int
        let trimStartFrame: Int
        let speed: Double
        let fps: Int
        let sourcePath: String
        let sourceFileSize: UInt64
        let sourceModificationTime: TimeInterval

        init(_ clip: Clip, fps: Int, sourceURL: URL) {
            mediaRef = clip.mediaRef
            startFrame = clip.startFrame
            durationFrames = clip.durationFrames
            trimStartFrame = clip.trimStartFrame
            speed = clip.speed
            self.fps = fps
            sourcePath = sourceURL.standardizedFileURL.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
            sourceFileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            sourceModificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        }
    }

    func detectBeats(
        clipId: String,
        tempoRange: ClosedRange<Double> = AudioBeatDetector.defaultTempoRange,
        bpmOverride: Double? = nil
    ) async throws -> BeatDetectionReport {
        guard let sourceClipId = canonicalBeatSourceClipId(for: clipId),
              let location = findClip(id: sourceClipId) else { throw BeatMarkerError.clipNotFound }
        let clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }),
              clip.mediaType == .audio || asset.hasAudio else {
            throw BeatMarkerError.noAudio
        }
        guard let sourceURL = mediaResolver.resolveURL(for: clip.mediaRef) else {
            throw BeatMarkerError.mediaOffline
        }
        let fpsInt = timeline.fps
        let fps = Double(fpsInt)
        guard fps > 0, clip.speed > 0 else { throw BeatMarkerError.noVisibleBeats }

        let timing = BeatClipTiming(clip, fps: fpsInt, sourceURL: sourceURL)
        let visibleSourceStart = Double(clip.trimStartFrame) / fps
        let visibleSourceEnd = Double(clip.trimStartFrame + clip.renderedSourceFramesConsumed) / fps
        var analysisStart = visibleSourceStart
        var analysisEnd = visibleSourceEnd

        // A short timeline slice can still borrow nearby source context to establish
        // tempo; only beats inside the visible clip are mapped below.
        // Four periods gives the tracker enough evidence even at the supported
        // 30 BPM floor (a fixed three seconds can contain only one or two beats).
        let slowestRelevantTempo = bpmOverride ?? tempoRange.lowerBound
        let minimumSpan = max(3.0, 4 * 60 / slowestRelevantTempo)
        if analysisEnd - analysisStart < minimumSpan, asset.duration > 0 {
            let missing = minimumSpan - (analysisEnd - analysisStart)
            analysisStart = max(0, analysisStart - missing / 2)
            analysisEnd = min(asset.duration, analysisEnd + missing / 2)
            if analysisEnd - analysisStart < minimumSpan {
                analysisStart = max(0, analysisEnd - minimumSpan)
                analysisEnd = min(asset.duration, max(analysisEnd, analysisStart + minimumSpan))
            }
        }

        let cacheKey = AudioBeatAnalysisCacheKey(
            detectorVersion: 2,
            sourcePath: timing.sourcePath,
            sourceFileSize: timing.sourceFileSize,
            sourceModificationTime: timing.sourceModificationTime,
            rangeStart: analysisStart,
            rangeEnd: analysisEnd,
            minimumBPM: tempoRange.lowerBound,
            maximumBPM: tempoRange.upperBound,
            bpmOverride: bpmOverride
        )
        let analysis: AudioBeatAnalysis
        if let cached = await AudioBeatAnalysisCache.shared.value(for: cacheKey) {
            analysis = cached
        } else {
            analysis = try await AudioBeatDetector.analyze(
                from: sourceURL,
                range: analysisStart...analysisEnd,
                tempoRange: tempoRange,
                bpmOverride: bpmOverride
            )
            await AudioBeatAnalysisCache.shared.insert(analysis, for: cacheKey)
        }
        try Task.checkCancellation()

        guard let currentLocation = findClip(id: sourceClipId) else { throw BeatMarkerError.clipNotFound }
        let currentClip = timeline.tracks[currentLocation.trackIndex].clips[currentLocation.clipIndex]
        guard let currentURL = mediaResolver.resolveURL(for: currentClip.mediaRef),
              BeatClipTiming(currentClip, fps: timeline.fps, sourceURL: currentURL) == timing else {
            throw BeatMarkerError.clipChanged
        }

        var mappedByFrame: [Int: TimelineBeat] = [:]
        for (index, beat) in analysis.beats.enumerated() {
            guard let timelineFrame = currentClip.timelineFrame(
                sourceSeconds: beat.sourceSeconds,
                fps: fpsInt
            ) else { continue }
            let mapped = TimelineBeat(index: index + 1, frame: timelineFrame, strength: beat.strength)
            if let existing = mappedByFrame[timelineFrame], existing.strength >= mapped.strength { continue }
            mappedByFrame[timelineFrame] = mapped
        }
        let beats = mappedByFrame.values.sorted { $0.frame < $1.frame }
        guard !beats.isEmpty else { throw BeatMarkerError.noVisibleBeats }

        return BeatDetectionReport(
            sourceClipId: sourceClipId,
            sourceTempoBPM: analysis.tempoBPM,
            timelineTempoBPM: analysis.tempoBPM * currentClip.effectivePlaybackSpeed,
            confidence: analysis.confidence,
            clipStartFrame: currentClip.startFrame,
            clipDurationFrames: currentClip.durationFrames,
            clipTrimStartFrame: currentClip.trimStartFrame,
            clipSpeed: currentClip.speed,
            beats: beats
        )
    }

    func canDetectBeats(clipId: String) -> Bool {
        guard let sourceClipId = canonicalBeatSourceClipId(for: clipId),
              let clip = clipFor(id: sourceClipId),
              let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return false }
        return clip.mediaType == .audio || asset.hasAudio
    }

    /// Linked video/audio pairs share one canonical grid on the audio bearer, so
    /// analysing each half cannot create duplicate guides at identical frames.
    func canonicalBeatSourceClipId(for clipId: String) -> String? {
        guard let clip = clipFor(id: clipId) else { return nil }
        if clip.mediaType == .video {
            for partnerId in linkedPartnerIds(of: clipId) {
                if clipFor(id: partnerId)?.mediaType == .audio { return partnerId }
            }
        }
        return clipId
    }

    /// Analyses the visible source span and atomically replaces only beat markers
    /// previously generated from this clip. Manual markers are never touched.
    @discardableResult
    func addBeatMarkers(
        clipId: String,
        everyNthBeat: Int = 1,
        beatOffset: Int = 0,
        tempoRange: ClosedRange<Double> = AudioBeatDetector.defaultTempoRange,
        bpmOverride: Double? = nil,
        minimumConfidence: Double = 0.45,
        allowLowConfidence: Bool = false,
        color: String? = "#58A822"
    ) async throws -> BeatMarkerReport {
        guard everyNthBeat >= 1, everyNthBeat <= 16,
              beatOffset >= 0, beatOffset < everyNthBeat else {
            throw BeatMarkerError.invalidSelection
        }
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw BeatMarkerError.invalidSelection
        }
        guard let sourceClipId = canonicalBeatSourceClipId(for: clipId) else {
            throw BeatMarkerError.clipNotFound
        }
        let requestId = UUID()
        beatMarkerRequestIds[sourceClipId] = requestId
        defer {
            if beatMarkerRequestIds[sourceClipId] == requestId {
                beatMarkerRequestIds.removeValue(forKey: sourceClipId)
            }
        }

        let detection = try await detectBeats(
            clipId: sourceClipId,
            tempoRange: tempoRange,
            bpmOverride: bpmOverride
        )
        guard beatMarkerRequestIds[sourceClipId] == requestId else {
            throw BeatMarkerError.superseded
        }
        if !allowLowConfidence, detection.confidence < minimumConfidence {
            throw BeatMarkerError.lowConfidence(detection.confidence)
        }

        var drafts: [BeatMarkerDraft] = []
        drafts.reserveCapacity(detection.beats.count / everyNthBeat + 1)
        for beat in detection.beats
            where (beat.index - 1) % everyNthBeat == beatOffset {
            drafts.append(BeatMarkerDraft(
                frame: beat.frame,
                beatIndex: beat.index,
                strength: beat.strength
            ))
        }

        guard !drafts.isEmpty else { throw BeatMarkerError.noVisibleBeats }
        guard drafts.count <= 2_000 else { throw BeatMarkerError.tooManyMarkers(drafts.count) }
        let markers = replaceGeneratedBeatMarkers(
            sourceClipId: sourceClipId,
            drafts: drafts,
            color: color
        )
        guard !markers.isEmpty else { throw BeatMarkerError.noVisibleBeats }

        return BeatMarkerReport(
            sourceClipId: sourceClipId,
            sourceTempoBPM: detection.sourceTempoBPM,
            timelineTempoBPM: detection.timelineTempoBPM,
            confidence: detection.confidence,
            everyNthBeat: everyNthBeat,
            detectedBeatCount: detection.beats.count,
            beats: detection.beats,
            markers: markers
        )
    }
}
