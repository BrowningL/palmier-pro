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
        for clipId in clipIds {
            guard let location = findClip(id: clipId) else { continue }
            var clip = timeline.tracks[location.trackIndex].clips[location.clipIndex]
            guard clip.mediaType == .audio else { continue }
            if dragBefore[clipId] == nil {
                dragBefore[clipId] = clip
            }
            clip.voiceCleanup = settings
            timeline.tracks[location.trackIndex].clips[location.clipIndex] = clip
        }
        // The proxy only changes on commit, so refreshing the video compositor on
        // every drag event wastes GPU work without changing the audible preview.
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
