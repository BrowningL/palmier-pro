import Foundation

struct TimelineMarkerDraft: Sendable, Equatable {
    var frame: Int
    var label: String?
    var color: String?
}

struct BeatMarkerDraft: Sendable, Equatable {
    var frame: Int
    var beatIndex: Int
    var strength: Double = 1
    var isDownbeat: Bool = false
    var sourceSeconds: Double? = nil
}

extension EditorViewModel {
    @discardableResult
    func addTimelineMarker(frame: Int, label: String? = nil, color: String? = nil) -> TimelineMarker {
        addTimelineMarkers([TimelineMarkerDraft(frame: frame, label: label, color: color)]).first!
    }

    @discardableResult
    func addTimelineMarkers(_ drafts: [TimelineMarkerDraft]) -> [TimelineMarker] {
        var added: [TimelineMarker] = []
        withTimelineSwap(actionName: drafts.count == 1 ? "Add Marker" : "Add Markers") {
            for draft in drafts {
                let label = normalizedMarkerLabel(draft.label)
                let marker = TimelineMarker(
                    frame: max(0, draft.frame),
                    label: label?.isEmpty == false ? label! : nextTimelineMarkerLabel(),
                    color: normalizedMarkerColor(draft.color)
                )
                timeline.markers.append(marker)
                added.append(marker)
            }
            sortTimelineMarkers()
        }
        return added
    }

    @discardableResult
    func updateTimelineMarkers(
        ids: Set<String>, frame: Int? = nil, label: String? = nil, color: String? = nil
    ) -> [TimelineMarker] {
        guard !ids.isEmpty, timeline.markers.contains(where: { ids.contains($0.id) }) else { return [] }
        invalidateBeatMarkerRequests(forMarkerIds: ids)
        var clipsById: [String: Clip] = [:]
        for clip in timeline.tracks.flatMap(\.clips) { clipsById[clip.id] = clip }
        var updated: [TimelineMarker] = []
        withTimelineSwap(actionName: "Change Marker") {
            for index in timeline.markers.indices where ids.contains(timeline.markers[index].id) {
                if let frame {
                    let clampedFrame = max(0, frame)
                    timeline.markers[index].frame = clampedFrame
                    if timeline.markers[index].kind == .beat,
                       let sourceClipId = timeline.markers[index].sourceClipId,
                       let source = clipsById[sourceClipId],
                       source.contains(timelineFrame: clampedFrame) {
                        let sourceFrame = Double(source.trimStartFrame)
                            + Double(clampedFrame - source.startFrame) * source.effectivePlaybackSpeed
                        timeline.markers[index].sourceSeconds = sourceFrame / Double(max(1, timeline.fps))
                    } else if timeline.markers[index].kind == .beat {
                        timeline.markers[index].sourceSeconds = nil
                    }
                }
                if let label { timeline.markers[index].label = normalizedMarkerLabel(label) ?? "" }
                if let color { timeline.markers[index].color = normalizedMarkerColor(color) }
                updated.append(timeline.markers[index])
            }
            sortTimelineMarkers()
        }
        return updated.sorted { $0.frame == $1.frame ? $0.label < $1.label : $0.frame < $1.frame }
    }

    func updateTimelineMarker(id: String, frame: Int? = nil, label: String? = nil, color: String? = nil) {
        updateTimelineMarkers(ids: [id], frame: frame, label: label, color: color)
    }

    func removeTimelineMarkers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        invalidateBeatMarkerRequests(forMarkerIds: ids)
        withTimelineSwap(actionName: ids.count == 1 ? "Delete Marker" : "Delete Markers") {
            timeline.markers.removeAll { ids.contains($0.id) }
        }
    }

    func timelineMarker(id: String) -> TimelineMarker? {
        timeline.markers.first { $0.id == id }
    }

    func timelineMarkers(matchingLabel label: String) -> [TimelineMarker] {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return timeline.markers.filter { $0.label.caseInsensitiveCompare(normalized) == .orderedSame }
    }

    func markerDisplayLabel(_ marker: TimelineMarker) -> String {
        if !marker.label.isEmpty { return marker.label }
        if marker.kind == .beat, let index = marker.beatIndex {
            return marker.isDownbeat ? "Downbeat \(index)" : "Beat \(index)"
        }
        return "Marker"
    }

    func generatedBeatMarkers(sourceClipId: String) -> [TimelineMarker] {
        timeline.activeMarkers.filter { $0.kind == .beat && $0.sourceClipId == sourceClipId }
    }

    @discardableResult
    func replaceGeneratedBeatMarkers(
        sourceClipId: String,
        drafts: [BeatMarkerDraft],
        color: String? = "#58A822"
    ) -> [TimelineMarker] {
        let hadExisting = timeline.markers.contains { $0.kind == .beat && $0.sourceClipId == sourceClipId }
        var added: [TimelineMarker] = []
        let signature = clipFor(id: sourceClipId)?.beatMarkerTimingSignature(fps: timeline.fps)
        withTimelineSwap(actionName: hadExisting ? "Replace Beat Markers" : "Add Beat Markers") {
            timeline.markers.removeAll { $0.kind == .beat && $0.sourceClipId == sourceClipId }
            var seenFrames = Set<Int>()
            for draft in drafts where seenFrames.insert(max(0, draft.frame)).inserted {
                let marker = TimelineMarker(
                    frame: max(0, draft.frame),
                    color: normalizedMarkerColor(color),
                    kind: .beat,
                    sourceClipId: sourceClipId,
                    sourceSeconds: draft.sourceSeconds,
                    beatIndex: max(1, draft.beatIndex),
                    strength: max(0, min(1, draft.strength)),
                    isDownbeat: draft.isDownbeat,
                    sourceTimingSignature: signature
                )
                timeline.markers.append(marker)
                added.append(marker)
            }
            sortTimelineMarkers()
        }
        return added.sorted { $0.frame < $1.frame }
    }

    func removeGeneratedBeatMarkers(sourceClipId: String) {
        beatMarkerRequestIds.removeValue(forKey: sourceClipId)
        guard timeline.markers.contains(where: { $0.kind == .beat && $0.sourceClipId == sourceClipId }) else { return }
        withTimelineSwap(actionName: "Delete Beat Markers") {
            timeline.markers.removeAll { $0.kind == .beat && $0.sourceClipId == sourceClipId }
        }
    }

    private func invalidateBeatMarkerRequests(forMarkerIds ids: Set<String>) {
        let sourceIds = Set(timeline.markers.compactMap { marker -> String? in
            ids.contains(marker.id) && marker.kind == .beat ? marker.sourceClipId : nil
        })
        for id in sourceIds { beatMarkerRequestIds.removeValue(forKey: id) }
    }

    private func nextTimelineMarkerLabel() -> String {
        let used = Set(timeline.markers.map(\.label))
        var index = timeline.markers.count(where: { $0.kind == .manual }) + 1
        while used.contains("Marker \(index)") { index += 1 }
        return "Marker \(index)"
    }

    private func sortTimelineMarkers() {
        timeline.markers.sort {
            $0.frame == $1.frame
                ? $0.label.localizedStandardCompare($1.label) == .orderedAscending
                : $0.frame < $1.frame
        }
    }

    private func normalizedMarkerLabel(_ raw: String?) -> String? {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMarkerColor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    }
}
