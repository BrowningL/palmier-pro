import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("ToolExecutor — persistent markers")
struct MarkerToolTests {
    @Test func manualMarkerToolsAddUpdateAndRemove() async throws {
        let h = ToolHarness()

        let added = try await h.runOK("add_markers", args: [
            "entries": [
                ["frame": 12, "label": "Hook", "color": "#FF8800"],
                ["frame": 48],
            ],
        ]) as? [String: Any]

        #expect((added?["markers"] as? [[String: Any]])?.count == 2)
        let firstId = try #require(h.editor.timeline.markers.first { $0.frame == 12 }?.id)
        _ = try await h.runOK("set_marker_properties", args: [
            "markerIds": [firstId],
            "frame": 18,
            "label": "Cold open",
            "color": "",
        ])
        #expect(h.editor.timelineMarker(id: firstId)?.frame == 18)
        #expect(h.editor.timelineMarker(id: firstId)?.label == "Cold open")
        #expect(h.editor.timelineMarker(id: firstId)?.color == nil)

        _ = try await h.runOK("remove_markers", args: ["markerIds": [firstId]])
        #expect(h.editor.timelineMarker(id: firstId) == nil)
        #expect(h.editor.timeline.markers.count == 1)
    }

    @Test func getTimelineGroupsActiveBeatsAndHidesInternalSignatures() async throws {
        let clip = Fixtures.clip(id: "audio-source", mediaType: .audio, start: 0, duration: 120)
        var timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        let signature = clip.beatMarkerTimingSignature(fps: timeline.fps)
        timeline.markers = [
            TimelineMarker(id: "manual", frame: 10, label: "Intro"),
            TimelineMarker(
                id: "beat-valid", frame: 30, kind: .beat, sourceClipId: clip.id,
                beatIndex: 1, strength: 1, isDownbeat: true, sourceTimingSignature: signature
            ),
            TimelineMarker(
                id: "beat-stale", frame: 60, kind: .beat, sourceClipId: clip.id,
                beatIndex: 2, strength: 1, sourceTimingSignature: "old timing"
            ),
        ]
        let h = ToolHarness(timeline: timeline)

        let raw = try await h.runOK("get_timeline") as? [String: Any]
        let manual = raw?["markers"] as? [[String: Any]]
        let groups = raw?["beatMarkerGroups"] as? [[String: Any]]
        let rows = groups?.first?["beats"] as? [[Any]]

        #expect(manual?.count == 1)
        #expect(manual?.first?["markerId"] as? String == "manual")
        #expect(groups?.count == 1)
        #expect(rows?.count == 1)
        #expect(rows?.first?[0] as? String == "beat-valid")
        #expect(rows?.first?[4] as? Bool == true)
        #expect(ToolHarness.textOf(await h.runRaw("get_timeline")).contains("sourceTimingSignature") == false)
    }

    @Test func removeGeneratedGridCanonicalizesLinkedVideoToAudio() async throws {
        var video = Fixtures.clip(id: "video", mediaRef: "linked", mediaType: .video, start: 0, duration: 90)
        var audio = Fixtures.clip(id: "audio", mediaRef: "linked", mediaType: .audio, start: 0, duration: 90)
        video.linkGroupId = "pair"
        audio.linkGroupId = "pair"
        var timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]), Fixtures.audioTrack(clips: [audio]),
        ])
        timeline.markers = [
            TimelineMarker(id: "keep", frame: 5, label: "Keep"),
            TimelineMarker(id: "beat", frame: 30, kind: .beat, sourceClipId: audio.id, beatIndex: 1),
        ]
        let h = ToolHarness(timeline: timeline)

        _ = try await h.runOK("remove_markers", args: ["sourceClipId": video.id])

        #expect(h.editor.timeline.markers.map(\.id) == ["keep"])
    }

    @Test func addBeatMarkersValidatesCadenceBeforeDetection() async {
        let h = ToolHarness()
        let result = await h.runRaw("add_beat_markers", args: [
            "clipId": "missing",
            "everyNthBeat": 0,
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("everyNthBeat"))
    }

    @Test func addBeatMarkersUsesCachedBeatStoreAnalysisAndExactProjectFrames() async throws {
        let mediaRef = "cached-beats-\(UUID().uuidString)"
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(mediaRef).caf")
        try Data([0]).write(to: sourceURL)
        let cacheURL = BeatDetector.cache.directory.appendingPathComponent(
            "\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_beats.json"
        )
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let analysis = BeatAnalysis(
            bpm: 120,
            beats: [0.5, 1, 1.5, 2],
            downbeats: [0.5, 1.5]
        )
        try JSONEncoder().encode(analysis).write(to: cacheURL)

        let clip = Fixtures.clip(
            id: "song", mediaRef: mediaRef, mediaType: .audio,
            start: 100, duration: 100, trimStart: 15, speed: 1.25
        )
        let h = ToolHarness(timeline: Fixtures.timeline(
            fps: 30, tracks: [Fixtures.audioTrack(clips: [clip])]
        ))
        let asset = MediaAsset(
            id: mediaRef, url: sourceURL, type: .audio, name: "Cached rhythm", duration: 4
        )
        asset.hasAudio = true
        h.editor.mediaAssets.append(asset)

        let payload = try await h.runOK("add_beat_markers", args: [
            "clipId": clip.id,
            "downbeatsOnly": true,
            "everyNthBeat": 2,
        ]) as? [String: Any]

        #expect(payload?["markerCount"] as? Int == 1)
        #expect(abs((payload?["timelineBPM"] as? Double ?? 0) - 150) < 0.001)
        let marker = try #require(h.editor.generatedBeatMarkers(sourceClipId: clip.id).first)
        #expect(marker.frame == 100)
        #expect(marker.beatIndex == 1)
        #expect(marker.isDownbeat)
        #expect(marker.sourceSeconds == 0.5)
        #expect(marker.sourceTimingSignature == clip.beatMarkerTimingSignature(fps: 30))
    }

    @Test func beatCadenceKeepsSourcePhaseAndMergesNearbyDownbeatsBeforeProjection() async throws {
        let mediaRef = "global-beats-\(UUID().uuidString)"
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(mediaRef).caf")
        try Data([0]).write(to: sourceURL)
        let cacheURL = BeatDetector.cache.directory.appendingPathComponent(
            "\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_beats.json"
        )
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let analysis = BeatAnalysis(
            bpm: 120,
            beats: [0.5, 1, 1.5, 2],
            downbeats: [0.51, 1.52]
        )
        try JSONEncoder().encode(analysis).write(to: cacheURL)

        // Source time before 1 second is trimmed off. Cadence still begins at
        // source beat 1, so every second beat selects global beat 3, not beat 2.
        let clip = Fixtures.clip(
            id: "trimmed-song", mediaRef: mediaRef, mediaType: .audio,
            start: 100, duration: 120, trimStart: 60, speed: 1
        )
        let h = ToolHarness(timeline: Fixtures.timeline(
            fps: 60, tracks: [Fixtures.audioTrack(clips: [clip])]
        ))
        let asset = MediaAsset(
            id: mediaRef, url: sourceURL, type: .audio, name: "Trimmed rhythm", duration: 4
        )
        asset.hasAudio = true
        h.editor.mediaAssets.append(asset)

        let payload = try await h.runOK("add_beat_markers", args: [
            "clipId": clip.id,
            "everyNthBeat": 2,
        ]) as? [String: Any]

        #expect(payload?["markerCount"] as? Int == 1)
        let marker = try #require(h.editor.generatedBeatMarkers(sourceClipId: clip.id).first)
        #expect(marker.frame == 131)
        #expect(marker.beatIndex == 3)
        #expect(marker.isDownbeat)
        #expect(marker.sourceSeconds == 1.52)
    }
}
