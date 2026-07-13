import Foundation

extension EditorViewModel {
    func setVoiceCleanup(clipIds: [String], enabled: Bool) {
        mutateClips(
            ids: Set(clipIds),
            actionName: enabled ? "Enable Voice Cleanup" : "Disable Voice Cleanup"
        ) { clip in
            guard clip.mediaType == .audio else { return }
            clip.voiceCleanup = enabled
                ? (clip.voiceCleanup ?? VoiceCleanupSettings())
                : nil
        }
    }

    func applyVoiceCleanupStrength(clipIds: [String], strength: Double) {
        let settings = VoiceCleanupSettings(strength: strength)
        applyClipProperties(clipIds: clipIds, rebuild: false) { clip in
            guard clip.mediaType == .audio else { return }
            clip.voiceCleanup = settings
        }
    }

    func commitVoiceCleanupStrength(clipIds: [String], strength: Double) {
        let settings = VoiceCleanupSettings(strength: strength)
        undoManager?.beginUndoGrouping()
        commitClipProperties(clipIds: clipIds) { clip in
            guard clip.mediaType == .audio else { return }
            clip.voiceCleanup = settings
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Change Voice Cleanup")
    }
}
