import Foundation

private struct AddBeatMarkersInput: DecodableToolArgs {
    let clipId: String
    let everyNthBeat: Int?
    let beatOffset: Int?
    let downbeatsOnly: Bool?
    let forceDetection: Bool?
    let color: String?
    static let allowedKeys: Set<String> = [
        "clipId", "everyNthBeat", "beatOffset", "downbeatsOnly", "forceDetection", "color",
    ]
}

extension ToolExecutor {
    func addBeatMarkers(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: AddBeatMarkersInput = try decodeToolArgs(args, path: "add_beat_markers")
        let every = input.everyNthBeat ?? 1
        let offset = input.beatOffset ?? 0
        guard (1...16).contains(every) else {
            throw ToolError("everyNthBeat must be between 1 and 16.")
        }
        guard (0..<every).contains(offset) else {
            throw ToolError("beatOffset must be >= 0 and less than everyNthBeat.")
        }
        if let color = input.color, TextStyle.RGBA(hex: color) == nil {
            throw ToolError("color must be #RGB, #RRGGBB, or #RRGGBBAA.")
        }
        let report = try await editor.addBeatMarkers(
            clipId: input.clipId,
            everyNthBeat: every,
            beatOffset: offset,
            downbeatsOnly: input.downbeatsOnly ?? false,
            forceDetection: input.forceDetection ?? false,
            color: input.color
        )
        let limit = 500
        let rows = report.markers.prefix(limit).map { marker -> [Any] in
            [marker.frame, marker.beatIndex ?? 0, marker.isDownbeat]
        }
        var payload: [String: Any] = [
            "sourceClipId": report.sourceClipId,
            "sourceBPM": report.sourceTempoBPM,
            "timelineBPM": report.timelineTempoBPM,
            "detectedBeatCount": report.detectedBeatCount,
            "markerCount": report.markers.count,
            "everyNthBeat": report.everyNthBeat,
            "beatFormat": ["frame", "beatIndex", "isDownbeat"],
            "beats": rows,
            "note": "Frames are exact project-frame guides and remain attached to the current clip timing.",
        ]
        if report.markers.count > limit { payload["outputTruncated"] = true }
        return .ok(Self.jsonString(payload) ?? "{}")
    }
}
