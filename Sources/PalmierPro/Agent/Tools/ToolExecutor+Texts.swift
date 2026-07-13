import Foundation

fileprivate struct PartialTextSpec {
    let trackId: String?
    let trackGroup: String?
    let startFrame: Int
    let durationFrames: Int
    let content: String
    let style: TextStyle
    let transform: Transform?
}

extension ToolExecutor {
    private static let addTextsAllowedKeys: Set<String> = [
        "trackIndex", "trackGroup", "startFrame", "durationFrames", "content",
        "transform", "fontName", "fontSize", "color", "alignment",
        "textPreset", "backgroundEnabled", "backgroundColor",
        "strokeEnabled", "strokeColor", "strokeWidth",
    ]

    private func parseAddTextTransform(
        _ tDict: [String: Any]?,
        content: String, style: TextStyle,
        canvas: (w: Double, h: Double),
        path: String
    ) throws -> Transform? {
        guard let tDict else { return nil }
        try validateUnknownKeys(tDict, allowed: ["centerX", "centerY", "width", "height"], path: "\(path).transform")
        let cX = tDict.double("centerX"), cY = tDict.double("centerY")
        let w = tDict.double("width"), h = tDict.double("height")
        if cX == nil && cY == nil && w == nil && h == nil { return nil }
        guard let cx = cX, let cy = cY else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        if let ww = w, let hh = h {
            return Transform(center: (cx, cy), width: ww, height: hh)
        }
        guard w == nil && h == nil else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvas.w) * 0.9, canvasHeight: CGFloat(canvas.h))
        return Transform(center: (cx, cy), width: Double(natural.width) / canvas.w, height: Double(natural.height) / canvas.h)
    }

    func addTexts(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        var partials: [PartialTextSpec] = []
        partials.reserveCapacity(rawEntries.count)

        for (idx, raw) in rawEntries.enumerated() {
            let path = "entries[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addTextsAllowedKeys, path: path)

            let trackIndex = entry.int("trackIndex")
            let trackGroup = entry.string("trackGroup")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trackGroup, trackGroup.isEmpty {
                throw ToolError("\(path): trackGroup must not be empty")
            }
            if trackIndex != nil, trackGroup != nil {
                throw ToolError("\(path): trackGroup is only valid when trackIndex is omitted")
            }
            let startFrame = try entry.requireInt("startFrame")
            let durationFrames = try entry.requireInt("durationFrames")
            let content = try entry.requireString("content")

            var trackId: String? = nil
            if let ti = trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                guard ClipType.text.isCompatible(with: editor.timeline.tracks[ti].type) else {
                    throw ToolError("\(path): track \(ti) is an audio track; text requires a video/image/text track")
                }
                trackId = editor.timeline.tracks[ti].id
            }
            guard durationFrames >= 1 else {
                throw ToolError("\(path): durationFrames must be >= 1 (got \(durationFrames))")
            }
            guard startFrame >= 0 else {
                throw ToolError("\(path): startFrame must be >= 0 (got \(startFrame))")
            }

            var style = TextStyle()
            if let preset = try parseTextPreset(entry.string("textPreset"), path: path) {
                style.apply(preset)
            }
            if let f = entry.string("fontName") { style.fontName = f }
            if let s = entry.double("fontSize") { style.fontSize = s }
            if let c = try parseColorHex(entry.string("color"), path: path) { style.color = c }
            if let a = try parseAlignment(entry.string("alignment"), path: path) { style.alignment = a }
            if let c = try parseColorHex(entry.string("backgroundColor"), path: path) {
                style.background.color = c
                style.background.enabled = true
            }
            if let enabled = entry["backgroundEnabled"] as? Bool { style.background.enabled = enabled }
            if let c = try parseColorHex(entry.string("strokeColor"), path: path) {
                style.border.color = c
                style.border.enabled = true
            }
            if let width = try parseStrokeWidth(entry.double("strokeWidth"), path: path) {
                style.border.width = width
                style.border.enabled = width > 0
            }
            if let enabled = entry["strokeEnabled"] as? Bool { style.border.enabled = enabled }
            if style.background.enabled { style.shadow.enabled = false }

            let transform = try parseAddTextTransform(
                entry["transform"] as? [String: Any],
                content: content, style: style,
                canvas: (Double(editor.timeline.width), Double(editor.timeline.height)),
                path: path
            )

            partials.append(.init(
                trackId: trackId,
                trackGroup: trackGroup,
                startFrame: startFrame,
                durationFrames: durationFrames,
                content: content,
                style: style,
                transform: transform
            ))
        }

        // All-or-none: a new track at index 0 would shift any explicit indices.
        let omittedCount = partials.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == partials.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(partials.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }
        let groupedCount = partials.filter { $0.trackGroup != nil }.count
        guard groupedCount == 0 || groupedCount == partials.count else {
            throw ToolError("Mixed trackGroup: when one auto-created entry uses trackGroup, every entry must use it.")
        }

        let actionName = partials.count == 1 ? "Add Text (Agent)" : "Add Texts (Agent)"
        let (ids, createdTrackInfo, resolvedSpecs) = try withUndoGroup(editor, actionName: actionName) {
            () -> ([String], [String], [EditorViewModel.TextClipSpec]) in
            var createdTrackInfo: [String] = []
            var createdTrackIds: [String] = []
            var trackIdByGroup: [String: String] = [:]
            let sharedGroup = "__shared__"
            if omittedCount == partials.count {
                let groups: [String]
                if groupedCount == partials.count {
                    groups = partials.compactMap(\.trackGroup).reduce(into: []) {
                        if !$0.contains($1) { $0.append($1) }
                    }
                } else {
                    groups = [sharedGroup]
                }
                // Insert in reverse so first-seen group remains the top track at index 0.
                for group in groups.reversed() {
                    let newIdx = editor.insertTrack(at: 0, type: .video)
                    guard editor.timeline.tracks.indices.contains(newIdx) else { continue }
                    let id = editor.timeline.tracks[newIdx].id
                    trackIdByGroup[group] = id
                    createdTrackIds.append(id)
                }
                for group in groups {
                    guard let id = trackIdByGroup[group],
                          let idx = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else { continue }
                    let label = editor.timelineTrackDisplayLabel(at: idx)
                    createdTrackInfo.append(group == sharedGroup
                        ? "track \(idx) ('\(label)')"
                        : "trackGroup '\(group)' -> track \(idx) ('\(label)')")
                }
            }

            let resolvedSpecs: [EditorViewModel.TextClipSpec] = partials.compactMap { p in
                let id = p.trackId ?? trackIdByGroup[p.trackGroup ?? sharedGroup]
                guard let id, let trackIdx = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else {
                    return nil
                }
                return .init(
                    trackIndex: trackIdx,
                    startFrame: p.startFrame,
                    durationFrames: p.durationFrames,
                    content: p.content,
                    style: p.style,
                    transform: p.transform
                )
            }
            guard resolvedSpecs.count == partials.count else {
                for id in createdTrackIds { editor.removeTrack(id: id) }
                throw ToolError("Failed to resolve every target text track")
            }

            let ids = editor.placeTextClips(resolvedSpecs)
            guard ids.count == resolvedSpecs.count else {
                for id in createdTrackIds { editor.removeTrack(id: id) }
                throw ToolError("Failed to place any text clips")
            }

            editor.undoManager?.registerUndo(withTarget: editor) { vm in
                vm.removeClips(ids: Set(ids))
            }
            return (ids, createdTrackInfo, resolvedSpecs)
        }
        editor.notifyTimelineChanged()

        let prefix = createdTrackInfo.isEmpty ? "" : "Created \(createdTrackInfo.joined(separator: "; ")). "
        let summary = zip(ids, resolvedSpecs).map { id, spec in
            "\(id) on track \(spec.trackIndex) @ frame \(spec.startFrame) for \(spec.durationFrames)"
        }.joined(separator: "; ")
        return .ok("\(prefix)Added \(ids.count) text clip\(ids.count == 1 ? "" : "s"): \(summary)")
    }
}
