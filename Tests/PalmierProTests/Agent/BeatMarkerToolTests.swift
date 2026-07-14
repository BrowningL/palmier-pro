import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("ToolExecutor — beat detection and markers")
@MainActor
struct BeatMarkerToolTests {
    @Test func detectBeatsMapsTrimSpeedAndTimelinePositionWithoutEditing() async throws {
        let fixture = try makeFixture(speed: 2)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let json = try await fixture.harness.runOK("detect_beats", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
        ]) as? [String: Any]

        #expect(fixture.harness.editor.timeline.markers.isEmpty)
        let timing = json?["clipTiming"] as? [String: Any]
        #expect(timing?["startFrame"] as? Int == 100)
        #expect(timing?["trimStartFrame"] as? Int == 30)
        #expect(timing?["speed"] as? Double == 2)
        #expect(abs((json?["timelineBPM"] as? Double ?? 0) - 240) < 0.001)
        let beats = json?["beats"] as? [[Any]]
        let frames = beats?.compactMap { $0.first as? Int } ?? []
        #expect(frames.allSatisfy { $0 >= 100 && $0 < 220 })
        #expect(frames.contains { abs($0 - 100) <= 1 })
        #expect(frames.contains { abs($0 - 108) <= 1 })
    }

    @Test func addBeatMarkersUsesOneUndoAndRerunPreservesManualMarkers() async throws {
        let fixture = try makeFixture(speed: 1)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let undoManager = UndoManager()
        fixture.harness.editor.undoManager = undoManager
        fixture.harness.editor.timeline.markers = [
            TimelineMarker(id: "manual", frame: 105, label: "Keep me"),
            TimelineMarker(id: "other-beat", frame: 110, kind: .beat, sourceClipId: "other", beatIndex: 1),
        ]

        let first = try await fixture.harness.runOK("add_beat_markers", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
            "everyNthBeat": 2,
            "allowLowConfidence": true,
        ]) as? [String: Any]
        let firstCount = first?["markerCount"] as? Int ?? 0
        #expect(firstCount > 2)
        #expect((first?["selectedBeatFrames"] as? [Int])?.count == firstCount)
        #expect(first?["beats"] == nil)
        #expect(fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip").count == firstCount)
        #expect(fixture.harness.editor.timelineMarker(id: "manual") != nil)
        #expect(fixture.harness.editor.timelineMarker(id: "other-beat") != nil)
        #expect(fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip")
            .allSatisfy { $0.color == "#58A822" })

        _ = try await fixture.harness.runOK("add_beat_markers", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
            "everyNthBeat": 4,
            "allowLowConfidence": true,
        ])
        let replacementCount = fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip").count
        #expect(replacementCount > 0 && replacementCount < firstCount)
        #expect(fixture.harness.editor.timelineMarker(id: "manual") != nil)
        #expect(fixture.harness.editor.timelineMarker(id: "other-beat") != nil)

        undoManager.undo()
        #expect(fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip").count == firstCount)
    }

    @Test func addBeatMarkersValidatesCadenceBeforeAnalysis() async {
        let h = ToolHarness()
        let result = await h.runRaw("add_beat_markers", args: [
            "clipId": "missing",
            "everyNthBeat": 0,
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("everyNthBeat"))
    }

    @Test func cleanRhythmPassesDefaultConfidenceGateWithoutOverride() async throws {
        let fixture = try makeFixture(speed: 1)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let json = try await fixture.harness.runOK("add_beat_markers", args: [
            "clipId": "song-clip",
        ]) as? [String: Any]

        #expect((json?["confidence"] as? Double ?? 0) >= 0.45)
        #expect((json?["markerCount"] as? Int ?? 0) > 0)
    }

    @Test func agentCannotQuietlyLowerConfidenceGate() async {
        let h = ToolHarness()
        let result = await h.runRaw("add_beat_markers", args: [
            "clipId": "missing",
            "minimumConfidence": 0.1,
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("explicit user acceptance"))
    }

    @Test func shortVisibleClipUsesNearbySourceContext() async throws {
        let fixture = try makeFixture(speed: 1, duration: 30, trimStart: 150)
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let json = try await fixture.harness.runOK("detect_beats", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
        ]) as? [String: Any]
        let frames = (json?["beats"] as? [[Any]])?.compactMap {
            $0.isEmpty ? nil : $0[0] as? Int
        } ?? []

        #expect(frames.contains(100))
        #expect(frames.contains(115))
        #expect(frames.allSatisfy { (100..<130).contains($0) })
    }

    @Test func shortClipAtThirtyBPMUsesTempoSizedSourceContext() async throws {
        let fixture = try makeFixture(
            speed: 1,
            duration: 30,
            trimStart: 0,
            sourceBPM: 30,
            sourcePhase: 0.2
        )
        defer { try? FileManager.default.removeItem(at: fixture.url) }

        let json = try await fixture.harness.runOK("detect_beats", args: [
            "clipId": "song-clip",
            "bpmOverride": 30,
        ]) as? [String: Any]
        let frames = (json?["beats"] as? [[Any]])?.compactMap { $0.first as? Int } ?? []

        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { (100..<130).contains($0) })
    }

    @Test func linkedVideoCanonicalizesToItsAudioBearer() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-linked-beats-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeRhythm(to: url, duration: 8, bpm: 120, phase: 1)

        var video = Fixtures.clip(
            id: "video", mediaRef: "linked-media", mediaType: .video,
            start: 0, duration: 180
        )
        var audio = Fixtures.clip(
            id: "audio", mediaRef: "linked-media", mediaType: .audio,
            start: 0, duration: 180
        )
        video.linkGroupId = "pair"
        audio.linkGroupId = "pair"
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
        let asset = MediaAsset(
            id: "linked-media", url: url, type: .video, name: "Linked", duration: 8
        )
        asset.hasAudio = true
        h.editor.mediaAssets.append(asset)
        h.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id, name: asset.name, type: .video,
            source: .external(absolutePath: url.path), duration: 8, hasAudio: true
        ))

        let json = try await h.runOK("add_beat_markers", args: [
            "clipId": "video",
            "bpmOverride": 120,
            "allowLowConfidence": true,
        ]) as? [String: Any]

        #expect(json?["clipId"] as? String == "audio")
        #expect(h.editor.generatedBeatMarkers(sourceClipId: "video").isEmpty)
        #expect(!h.editor.generatedBeatMarkers(sourceClipId: "audio").isEmpty)
        #expect(h.editor.canDetectBeats(clipId: "video"))
        #expect(h.editor.canDetectBeats(clipId: "audio"))

        _ = try await h.runOK("remove_markers", args: ["sourceClipId": "video"])
        #expect(h.editor.generatedBeatMarkers(sourceClipId: "audio").isEmpty)
    }

    @Test func deletingOneGeneratedBeatSupersedesAnOlderInFlightReplacement() async throws {
        let fixture = try makeFixture(speed: 1)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let marker = TimelineMarker(
            id: "existing-beat",
            frame: 110,
            kind: .beat,
            sourceClipId: "song-clip",
            beatIndex: 1
        )
        fixture.harness.editor.timeline.markers = [marker]

        async let pending = fixture.harness.runRaw("add_beat_markers", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
            "allowLowConfidence": true,
        ])
        while fixture.harness.editor.beatMarkerRequestIds["song-clip"] == nil {
            await Task.yield()
        }
        fixture.harness.editor.removeTimelineMarkers(ids: [marker.id])

        let result = await pending
        #expect(result.isError)
        #expect(fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip").isEmpty)
    }

    @Test func readOnlyDetectionNeverClaimsAConcurrentUserEditForAgentUndo() async throws {
        let fixture = try makeFixture(speed: 1)
        defer { try? FileManager.default.removeItem(at: fixture.url) }
        let undoManager = UndoManager()
        fixture.harness.editor.undoManager = undoManager

        async let pending = fixture.harness.runRaw("detect_beats", args: [
            "clipId": "song-clip",
            "bpmOverride": 120,
        ])
        try await Task.sleep(for: .milliseconds(10))
        let userMarker = fixture.harness.editor.addTimelineMarker(frame: 102, label: "User marker")
        _ = await pending

        let undoResult = await fixture.harness.runRaw("undo")
        #expect(undoResult.isError)
        #expect(fixture.harness.editor.timelineMarker(id: userMarker.id) != nil)
    }

    @Test func relinkingMusicRetiresItsOldGeneratedGrid() async throws {
        let fixture = try makeFixture(speed: 1)
        let replacementURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-agent-relinked-beats-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.removeItem(at: replacementURL)
        }
        try writeRhythm(to: replacementURL, duration: 12, bpm: 90, phase: 0.4)
        fixture.harness.editor.timeline.markers = [
            TimelineMarker(
                id: "old-grid",
                frame: 110,
                kind: .beat,
                sourceClipId: "song-clip",
                beatIndex: 1
            ),
            TimelineMarker(id: "manual", frame: 115, label: "Keep"),
        ]
        fixture.harness.editor.beatMarkerRequestIds["song-clip"] = UUID()

        fixture.harness.editor.relinkAsset(id: "song-media", to: replacementURL)

        #expect(fixture.harness.editor.generatedBeatMarkers(sourceClipId: "song-clip").isEmpty)
        #expect(fixture.harness.editor.timelineMarker(id: "manual") != nil)
        #expect(fixture.harness.editor.beatMarkerRequestIds["song-clip"] == nil)
    }

    private func makeFixture(
        speed: Double,
        duration: Int = 120,
        trimStart: Int = 30,
        sourceBPM: Double = 120,
        sourcePhase: Double = 1
    ) throws -> (harness: ToolHarness, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pp-agent-beats-\(UUID().uuidString).caf")
        try writeRhythm(to: url, duration: 12, bpm: sourceBPM, phase: sourcePhase)

        var clip = Fixtures.clip(
            id: "song-clip",
            mediaRef: "song-media",
            mediaType: .audio,
            start: 100,
            duration: duration,
            trimStart: trimStart,
            speed: speed
        )
        clip.sourceClipType = .audio
        let timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(clips: [clip])])
        let h = ToolHarness(timeline: timeline)
        let asset = MediaAsset(id: "song-media", url: url, type: .audio, name: "Song", duration: 12)
        asset.hasAudio = true
        h.editor.mediaAssets.append(asset)
        h.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: asset.id,
            name: asset.name,
            type: .audio,
            source: .external(absolutePath: url.path),
            duration: asset.duration,
            hasAudio: true
        ))
        return (h, url)
    }

    private func writeRhythm(to url: URL, duration: Double, bpm: Double, phase: Double) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: AudioBeatDetector.sampleRate,
            channels: 1
        ) else { throw NSError(domain: "BeatMarkerToolTests", code: 1) }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = Int((duration * AudioBeatDetector.sampleRate).rounded())
        let period = 60 / bpm
        var position = 0
        while position < total {
            let count = min(4_096, total - position)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw NSError(domain: "BeatMarkerToolTests", code: 2)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                let time = Double(position + index) / AudioBeatDetector.sampleRate
                let shifted = time - phase
                let local = shifted >= 0 ? shifted.truncatingRemainder(dividingBy: period) : period
                if local < 0.04 {
                    let pulse = exp(-local * 80)
                        * (0.7 * sin(2 * .pi * 90 * local) + 0.3 * sin(2 * .pi * 2_200 * local))
                    channel[index] = Float(pulse * 0.8)
                } else {
                    channel[index] = Float(0.01 * sin(2 * .pi * 330 * time))
                }
            }
            try file.write(from: buffer)
            position += count
        }
    }
}
