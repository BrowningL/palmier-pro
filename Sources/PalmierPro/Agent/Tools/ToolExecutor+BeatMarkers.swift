import Foundation

fileprivate struct DetectBeatsInput: DecodableToolArgs {
    let clipId: String
    let minBPM: Double?
    let maxBPM: Double?
    let bpmOverride: Double?
    let startFrame: Int?
    let endFrame: Int?

    static let allowedKeys: Set<String> = [
        "clipId", "minBPM", "maxBPM", "bpmOverride", "startFrame", "endFrame",
    ]
}

fileprivate struct AddBeatMarkersInput: DecodableToolArgs {
    let clipId: String
    let everyNthBeat: Int?
    let beatOffset: Int?
    let minBPM: Double?
    let maxBPM: Double?
    let bpmOverride: Double?
    let minimumConfidence: Double?
    let allowLowConfidence: Bool?
    let color: String?

    static let allowedKeys: Set<String> = [
        "clipId", "everyNthBeat", "beatOffset", "minBPM", "maxBPM", "bpmOverride",
        "minimumConfidence", "allowLowConfidence", "color",
    ]
}

extension ToolExecutor {
    private static var beatOutputRowLimit: Int { 500 }

    func detectBeats(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: DetectBeatsInput = try decodeToolArgs(args, path: "detect_beats")
        let tempoRange = try beatTempoRange(minimum: input.minBPM, maximum: input.maxBPM)
        try validateBPMOverride(input.bpmOverride)
        try validateBeatOutputWindow(start: input.startFrame, end: input.endFrame)

        let report = try await editor.detectBeats(
            clipId: input.clipId,
            tempoRange: tempoRange,
            bpmOverride: input.bpmOverride
        )
        return .ok(Self.jsonString(beatDetectionPayload(
            report,
            startFrame: input.startFrame,
            endFrame: input.endFrame
        )) ?? "{}")
    }

    func addBeatMarkers(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: AddBeatMarkersInput = try decodeToolArgs(args, path: "add_beat_markers")
        let tempoRange = try beatTempoRange(minimum: input.minBPM, maximum: input.maxBPM)
        try validateBPMOverride(input.bpmOverride)

        let every = input.everyNthBeat ?? 1
        guard (1...16).contains(every) else {
            throw ToolError("add_beat_markers: everyNthBeat must be between 1 and 16.")
        }
        let offset = input.beatOffset ?? 0
        guard offset >= 0, offset < every else {
            throw ToolError("add_beat_markers: beatOffset must be >= 0 and less than everyNthBeat (\(every)).")
        }
        let minimumConfidence = input.minimumConfidence ?? 0.45
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw ToolError("add_beat_markers: minimumConfidence must be between 0 and 1.")
        }
        let allowLowConfidence = input.allowLowConfidence ?? false
        guard allowLowConfidence || minimumConfidence >= 0.45 else {
            throw ToolError("add_beat_markers: lowering minimumConfidence below 0.45 requires explicit user acceptance and allowLowConfidence=true.")
        }
        let color = try beatMarkerColor(input.color)

        let report = try await editor.addBeatMarkers(
            clipId: input.clipId,
            everyNthBeat: every,
            beatOffset: offset,
            tempoRange: tempoRange,
            bpmOverride: input.bpmOverride,
            minimumConfidence: minimumConfidence,
            allowLowConfidence: allowLowConfidence,
            color: color
        )

        let selectedRows = report.markers.prefix(Self.beatOutputRowLimit).map {
            [$0.frame, $0.beatIndex ?? 0, roundedBeatValue($0.strength ?? 0)] as [Any]
        }

        var payload: [String: Any] = [
            "clipId": report.sourceClipId,
            "sourceBPM": roundedBeatValue(report.sourceTempoBPM),
            "timelineBPM": roundedBeatValue(report.timelineTempoBPM),
            "confidence": roundedBeatValue(report.confidence),
            "detectedBeatCount": report.detectedBeatCount,
            "markerCount": report.markers.count,
            "everyNthBeat": report.everyNthBeat,
            "selectedBeatFormat": ["frame", "beatIndex", "strength"],
            "selectedBeats": Array(selectedRows),
            "selectedBeatFrames": report.markers.prefix(Self.beatOutputRowLimit).map(\.frame),
            "note": "selectedBeats/selectedBeatFrames are the everyNthBeat cadence boundaries. They are not classified musical downbeats or bars. A montage with N complete photos needs N+1 boundaries.",
        ]
        if report.markers.count > Self.beatOutputRowLimit {
            payload["outputTruncated"] = true
            payload["outputNote"] = "Use get_timeline with startFrame/endFrame to page the visible beat-marker group."
        }
        if report.confidence < 0.65 {
            payload["warning"] = "The rhythm is somewhat ambiguous. Preview several cuts before treating this as a final grid."
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func beatTempoRange(minimum: Double?, maximum: Double?) throws -> ClosedRange<Double> {
        let minBPM = minimum ?? AudioBeatDetector.defaultTempoRange.lowerBound
        let maxBPM = maximum ?? AudioBeatDetector.defaultTempoRange.upperBound
        guard minBPM.isFinite, maxBPM.isFinite,
              minBPM >= 30, maxBPM <= 300, minBPM < maxBPM else {
            throw ToolError("Beat tempo range must satisfy 30 <= minBPM < maxBPM <= 300.")
        }
        return minBPM...maxBPM
    }

    private func validateBPMOverride(_ bpm: Double?) throws {
        guard let bpm else { return }
        guard bpm.isFinite, (30...300).contains(bpm) else {
            throw ToolError("bpmOverride must be between 30 and 300.")
        }
    }

    private func validateBeatOutputWindow(start: Int?, end: Int?) throws {
        if let start, start < 0 { throw ToolError("startFrame must be >= 0.") }
        if let end, end < 0 { throw ToolError("endFrame must be >= 0.") }
        if let start, let end, end <= start {
            throw ToolError("endFrame must be greater than startFrame.")
        }
    }

    private func beatMarkerColor(_ raw: String?) throws -> String {
        let color = raw ?? "#58A822"
        let hex = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard (hex.count == 6 || hex.count == 8), UInt64(hex, radix: 16) != nil else {
            throw ToolError("color must be a 6- or 8-digit hex color.")
        }
        return "#\(hex.uppercased())"
    }

    private func beatDetectionPayload(
        _ report: EditorViewModel.BeatDetectionReport,
        startFrame: Int?,
        endFrame: Int?
    ) -> [String: Any] {
        let lowerBound = startFrame ?? Int.min
        let upperBound = endFrame ?? Int.max
        let inWindow = report.beats.filter {
            $0.frame >= lowerBound && $0.frame < upperBound
        }
        let visible = Array(inWindow.prefix(Self.beatOutputRowLimit))
        var payload: [String: Any] = [
            "clipId": report.sourceClipId,
            "sourceBPM": roundedBeatValue(report.sourceTempoBPM),
            "timelineBPM": roundedBeatValue(report.timelineTempoBPM),
            "confidence": roundedBeatValue(report.confidence),
            "clipTiming": [
                "startFrame": report.clipStartFrame,
                "durationFrames": report.clipDurationFrames,
                "trimStartFrame": report.clipTrimStartFrame,
                "speed": roundedBeatValue(report.clipSpeed),
            ],
            "beatCount": report.beats.count,
            "windowBeatCount": inWindow.count,
            "beatFormat": ["frame", "beatIndex", "strength"],
            "beats": beatRows(visible),
            "note": "Frames are already mapped to the current timeline clip. Re-detect after moving, trimming, or changing its speed.",
        ]
        if inWindow.count > visible.count, let last = visible.last {
            payload["nextStartFrame"] = last.frame + 1
            payload["outputNote"] = "Continue with startFrame=nextStartFrame; rows are capped at \(Self.beatOutputRowLimit)."
        }
        if report.confidence < 0.65 {
            payload["warning"] = "Low or moderate confidence: use a BPM override when known and preview several proposed cut points."
        }
        return payload
    }

    private func beatRows(_ beats: [EditorViewModel.TimelineBeat]) -> [[Any]] {
        beats.map { [$0.frame, $0.index, roundedBeatValue($0.strength)] }
    }

    private func roundedBeatValue(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }
}
