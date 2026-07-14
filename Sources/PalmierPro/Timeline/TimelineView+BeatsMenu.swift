import AppKit

extension TimelineView {
    @objc func performAddBeatMarkers(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let everyNthBeat = info["everyNthBeat"] as? Int else { return }
        let downbeatsOnly = info["downbeatsOnly"] as? Bool ?? false
        Task { @MainActor [weak self] in
            guard let self else { return }
            editor.mediaPanelToast = MediaPanelToast(message: "Analysing the audio beat…", kind: .success)
            do {
                let report = try await editor.addBeatMarkers(
                    clipId: clipId,
                    everyNthBeat: everyNthBeat,
                    downbeatsOnly: downbeatsOnly
                )
                let bpm = report.timelineTempoBPM > 0 ? " · \(Int(report.timelineTempoBPM.rounded())) BPM" : ""
                editor.mediaPanelToast = MediaPanelToast(
                    message: "Added \(report.markers.count) beat guides\(bpm).",
                    kind: .success
                )
            } catch EditorViewModel.BeatMarkerError.superseded {
                return
            } catch {
                editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription, kind: .warning)
            }
            needsDisplay = true
        }
    }

    @objc func performRemoveBeatMarkers(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.removeGeneratedBeatMarkers(sourceClipId: clipId)
        editor.mediaPanelToast = MediaPanelToast(message: "Removed beat guides.", kind: .success)
        needsDisplay = true
    }

    @objc func toggleMarkBeats(_ sender: Any?) {
        editor.markBeats.toggle()
    }

    @objc func performDetectBeats(_ sender: Any?) {
        guard let mediaRef = (sender as? NSMenuItem)?.representedObject as? String,
              let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else { return }
        let force = editor.mediaVisualCache.beats.analysis(for: mediaRef) != nil
        editor.markBeats = true
        let task = editor.mediaVisualCache.beats.detect(for: asset, force: force)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let analysis = try? await task.value {
                if analysis.beats.isEmpty && analysis.downbeats.isEmpty {
                    editor.mediaPanelToast = MediaPanelToast(message: "No beats detected.", kind: .warning)
                } else {
                    let count = max(analysis.beats.count, analysis.downbeats.count)
                    let bpm = analysis.bpm > 0 ? "\(Int(analysis.bpm.rounded())) BPM, " : ""
                    editor.mediaPanelToast = MediaPanelToast(message: "Detected \(bpm)\(count) beats.", kind: .success)
                }
            } else {
                editor.mediaPanelToast = MediaPanelToast(
                    message: "Beat detection failed. Check that the media file is reachable, then retry.",
                    kind: .warning
                )
            }
            needsDisplay = true
        }
    }
}
