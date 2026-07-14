import AppKit

extension TimelineView {
    @objc func performAddBeatMarkers(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let clipId = info["clipId"] as? String,
              let everyNthBeat = info["everyNthBeat"] as? Int else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            editor.mediaPanelToast = MediaPanelToast(
                message: "Analysing the audio beat…",
                kind: .success
            )
            do {
                let report = try await editor.addBeatMarkers(
                    clipId: clipId,
                    everyNthBeat: everyNthBeat
                )
                showBeatMarkerSuccess(report)
            } catch EditorViewModel.BeatMarkerError.lowConfidence(let confidence) {
                let alert = NSAlert()
                alert.messageText = "The beat is uncertain"
                alert.informativeText = "Palmier is only \(Int((confidence * 100).rounded()))% confident in this rhythm. Preview several cuts carefully if you create the grid anyway."
                alert.addButton(withTitle: "Create Anyway")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    do {
                        let report = try await editor.addBeatMarkers(
                            clipId: clipId,
                            everyNthBeat: everyNthBeat,
                            allowLowConfidence: true
                        )
                        showBeatMarkerSuccess(report)
                    } catch EditorViewModel.BeatMarkerError.superseded {
                        return
                    } catch {
                        editor.mediaPanelToast = MediaPanelToast(
                            message: error.localizedDescription,
                            kind: .warning
                        )
                    }
                } else {
                    editor.mediaPanelToast = MediaPanelToast(
                        message: "Beat markers were not added.",
                        kind: .warning
                    )
                }
            } catch EditorViewModel.BeatMarkerError.superseded {
                return
            } catch {
                editor.mediaPanelToast = MediaPanelToast(
                    message: error.localizedDescription,
                    kind: .warning
                )
            }
            needsDisplay = true
        }
    }

    private func showBeatMarkerSuccess(_ report: EditorViewModel.BeatMarkerReport) {
        let bpm = Int(report.timelineTempoBPM.rounded())
        let confidence = Int((report.confidence * 100).rounded())
        editor.mediaPanelToast = MediaPanelToast(
            message: "Added \(report.markers.count) beat markers · \(bpm) BPM · \(confidence)% confidence.",
            kind: report.confidence >= 0.65 ? .success : .warning
        )
    }

    @objc func performRemoveBeatMarkers(_ sender: Any?) {
        guard let clipId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        editor.removeGeneratedBeatMarkers(sourceClipId: clipId)
        editor.mediaPanelToast = MediaPanelToast(message: "Removed beat markers.", kind: .success)
        needsDisplay = true
    }
}
