import Foundation

private struct AddMarkersInput: DecodableToolArgs {
    struct Entry: DecodableToolArgs {
        let frame: Int
        let label: String?
        let color: String?
        static let allowedKeys: Set<String> = ["frame", "label", "color"]
    }
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]
}

private struct SetMarkerPropertiesInput: DecodableToolArgs {
    let markerIds: [String]
    let frame: Int?
    let label: String?
    let color: String?
    static let allowedKeys: Set<String> = ["markerIds", "frame", "label", "color"]
}

extension ToolExecutor {
    func addMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddMarkersInput = try decodeToolArgs(args, path: "add_markers")
        guard !input.entries.isEmpty else { throw ToolError("entries must not be empty.") }
        let rawEntries = args["entries"] as? [[String: Any]] ?? []
        for (index, entry) in input.entries.enumerated() {
            guard entry.frame >= 0 else { throw ToolError("entries[\(index)].frame must be >= 0.") }
            try validateMarkerColor(entry.color, path: "entries[\(index)].color")
            if rawEntries.indices.contains(index) {
                let raw = rawEntries[index]
                try validateUnknownKeys(raw, allowed: AddMarkersInput.Entry.allowedKeys, path: "entries[\(index)]")
            }
        }
        let markers = editor.addTimelineMarkers(input.entries.map {
            TimelineMarkerDraft(frame: $0.frame, label: $0.label, color: $0.color)
        })
        return .ok(Self.jsonString(["markers": markers.map(Self.markerInfo)]) ?? "{}")
    }

    func setMarkerProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetMarkerPropertiesInput = try decodeToolArgs(args, path: "set_marker_properties")
        guard !input.markerIds.isEmpty else { throw ToolError("markerIds must not be empty.") }
        guard input.frame != nil || input.label != nil || input.color != nil else {
            throw ToolError("Provide frame, label, or color.")
        }
        if let frame = input.frame, frame < 0 { throw ToolError("frame must be >= 0.") }
        try validateMarkerColor(input.color, path: "color", allowEmpty: true)
        for id in input.markerIds where editor.timelineMarker(id: id) == nil {
            throw ToolError("Marker not found: \(id)")
        }
        let markers = editor.updateTimelineMarkers(
            ids: Set(input.markerIds),
            frame: input.frame,
            label: input.label,
            color: input.color
        )
        return .ok(Self.jsonString(["markers": markers.map(Self.markerInfo)]) ?? "{}")
    }

    func removeMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["markerIds", "sourceClipId"], path: "remove_markers")
        let markerIds = args.stringArray("markerIds")
        let requestedSourceId = args.string("sourceClipId")
        guard !markerIds.isEmpty || requestedSourceId != nil else {
            throw ToolError("Provide markerIds or sourceClipId.")
        }
        for id in markerIds where editor.timelineMarker(id: id) == nil {
            throw ToolError("Marker not found: \(id)")
        }
        let sourceId = requestedSourceId.map { editor.canonicalBeatSourceClipId(for: $0) ?? $0 }
        let generatedIds: Set<String> = if let sourceId {
            Set(editor.timeline.markers.compactMap { marker -> String? in
                marker.kind == .beat && marker.sourceClipId == sourceId ? marker.id : nil
            })
        } else {
            []
        }
        let removalIds = Set(markerIds).union(generatedIds)
        editor.removeTimelineMarkers(ids: removalIds)
        return .ok(Self.jsonString([
            "removedMarkerIds": Array(removalIds),
            "removedGeneratedBeatMarkers": generatedIds.count,
        ]) ?? "{}")
    }

    private static func markerInfo(_ marker: TimelineMarker) -> [String: Any] {
        var info: [String: Any] = ["markerId": marker.id, "frame": marker.frame, "label": marker.label]
        if let color = marker.color { info["color"] = color }
        if marker.kind == .beat {
            info["kind"] = "beat"
            if let source = marker.sourceClipId { info["sourceClipId"] = source }
            if let index = marker.beatIndex { info["beatIndex"] = index }
            if marker.isDownbeat { info["downbeat"] = true }
        }
        return info
    }

    private func validateMarkerColor(_ raw: String?, path: String, allowEmpty: Bool = false) throws {
        guard let raw else { return }
        if allowEmpty, raw.isEmpty { return }
        guard TextStyle.RGBA(hex: raw) != nil else {
            throw ToolError("\(path) must be #RGB, #RRGGBB, or #RRGGBBAA.")
        }
    }
}
