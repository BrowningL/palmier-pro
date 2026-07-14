import Foundation

enum SocialAudioMixError: LocalizedError {
    case noAudioClips
    case unsupportedMusicFile(String)
    case unreadableMusicFile(String)
    case noReadableAudio
    case projectChangedDuringAnalysis
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noAudioClips:
            "Add or select some audio before balancing the project."
        case .unsupportedMusicFile(let name):
            "\(name) is not a supported audio file."
        case .unreadableMusicFile(let name):
            "Palmier Pro could not read audio from \(name)."
        case .noReadableAudio:
            "None of the project audio could be analyzed. Check that the source files are online."
        case .projectChangedDuringAnalysis:
            "The project audio changed during analysis. Run Balance again to use the latest edit."
        case .alreadyRunning:
            "Audio balancing is already running."
        }
    }
}

private struct SocialAudioAnalysisRequest: Sendable {
    let clip: Clip
    let sourceURL: URL
    let role: SocialAudioRole
    let range: ClosedRange<Double>
    let fps: Int
    let fileTag: String
}

private struct SocialAudioAnalysisResult: Sendable {
    let request: SocialAudioAnalysisRequest
    let analysis: AudioLoudnessAnalysis?
    let speechActivity: [SocialAudioActivityRange]
    let errorMessage: String?
}

private enum SocialAudioAnalysisWork {
    private static let analysisGate = AsyncSemaphore(value: 2)

    static func analyze(_ request: SocialAudioAnalysisRequest) async -> SocialAudioAnalysisResult {
        do {
            try await analysisGate.wait()
            defer { Task { await analysisGate.signal() } }
            try Task.checkCancellation()

            let analysis: AudioLoudnessAnalysis
            if request.clip.hasDenoiseEnabled, request.clip.denoiseAmount > 0 {
                let wetURL = try await AudioEnhancer.denoisedAudio(
                    for: request.sourceURL,
                    mediaRef: request.clip.mediaRef
                )
                analysis = try await AudioLoudnessAnalyzer.analyzeBlend(
                    dryURL: request.sourceURL,
                    wetURL: wetURL,
                    strength: request.clip.denoiseAmount,
                    range: request.range
                )
            } else {
                analysis = try await AudioLoudnessAnalyzer.analyze(
                    from: request.sourceURL,
                    range: request.range
                )
            }
            var vad: VoiceActivity.Analysis?
            if request.role == .voice {
                vad = try? await VoiceActivity.analysis(
                    for: request.sourceURL,
                    mediaRef: request.clip.mediaRef
                )
            }
            let speechActivity = vad?.segments.map {
                SocialAudioActivityRange(startSeconds: $0.start, endSeconds: $0.end)
            } ?? analysis.activityRanges.map {
                SocialAudioActivityRange(startSeconds: $0.lowerBound, endSeconds: $0.upperBound)
            }
            return SocialAudioAnalysisResult(
                request: request,
                analysis: analysis,
                speechActivity: speechActivity,
                errorMessage: nil
            )
        } catch {
            return SocialAudioAnalysisResult(
                request: request,
                analysis: nil,
                speechActivity: [],
                errorMessage: error.localizedDescription
            )
        }
    }
}

extension EditorViewModel {
    func setSocialAudioRole(clipIds: [String], role: SocialAudioRole) {
        let ids = Set(clipIds)
        mutateClips(ids: ids, actionName: "Set Audio Role") { clip in
            var settings = clip.socialAudio ?? SocialAudioSettings(role: role, preset: socialAudioPreset)
            settings.role = role
            settings.preset = socialAudioPreset
            settings.measuredLoudnessLUFS = nil
            settings.measuredPeakDbFS = nil
            settings.normalizationGainDb = 0
            settings.speechActivity = []
            settings.duckingAmountDb = role == .music ? socialAudioPreset.musicDuckDb : 0
            clip.socialAudio = settings
        }
        socialAudioMixMessage = "Role changed to \(role.displayName). Run Balance for Social to remeasure it."
    }

    func clearSocialAudioMix(clipIds: [String]) {
        mutateClips(ids: Set(clipIds), actionName: "Remove Social Audio Mix") { clip in
            clip.socialAudio = nil
        }
        socialAudioMixMessage = "Automatic gain and ducking removed from the selected audio."
    }

    /// Analyze source audio once, then persist a non-destructive recipe. Preview and export
    /// consume ordinary AVAudioMix ramps, so this adds no live DSP and cannot shift lip sync.
    func balanceSocialAudio(
        preset: SocialAudioPreset? = nil,
        roleOverrides: [String: SocialAudioRole] = [:]
    ) async throws {
        guard !isSocialAudioMixing else { throw SocialAudioMixError.alreadyRunning }
        let preset = preset ?? socialAudioPreset
        socialAudioPreset = preset

        let analyzedTimelineId = activeTimelineId
        let clips = timeline.tracks.flatMap(\.clips).filter { $0.mediaType == .audio && $0.durationFrames > 0 }
        guard !clips.isEmpty else { throw SocialAudioMixError.noAudioClips }

        isSocialAudioMixing = true
        socialAudioMixMessage = "Analyzing loudness and spoken sections…"
        defer { isSocialAudioMixing = false }

        let fps = Double(max(1, timeline.fps))
        let requests: [SocialAudioAnalysisRequest] = clips.compactMap { clip in
            guard let sourceURL = mediaResolver.resolveURL(for: clip.mediaRef) else { return nil }
            let role = roleOverrides[clip.id] ?? socialAudioRole(for: clip)
            let lower = Double(max(0, clip.trimStartFrame)) / fps
            let sourceFrames = clip.speed == 1
                ? clip.durationFrames
                : max(1, Int(Double(clip.durationFrames) * clip.speed))
            let upper = Double(max(0, clip.trimStartFrame + sourceFrames)) / fps
            guard upper > lower else { return nil }
            return SocialAudioAnalysisRequest(
                clip: clip,
                sourceURL: sourceURL,
                role: role,
                range: lower...upper,
                fps: timeline.fps,
                fileTag: DiskCache.sizeMtimeTag(for: sourceURL)
            )
        }
        guard !requests.isEmpty else { throw SocialAudioMixError.noReadableAudio }

        let results = await withTaskGroup(of: SocialAudioAnalysisResult.self) { group in
            for request in requests {
                group.addTask { await SocialAudioAnalysisWork.analyze(request) }
            }
            var output: [SocialAudioAnalysisResult] = []
            for await result in group { output.append(result) }
            return output
        }
        try Task.checkCancellation()
        let currentAudioClips = timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType == .audio && $0.durationFrames > 0
        }
        guard activeTimelineId == analyzedTimelineId,
              currentAudioClips == clips,
              socialAudioPreset == preset else {
            throw SocialAudioMixError.projectChangedDuringAnalysis
        }

        var settingsById: [String: SocialAudioSettings] = [:]
        var failures = 0
        guard results.allSatisfy({ socialAudioRequestIsCurrent($0.request) }) else {
            throw SocialAudioMixError.projectChangedDuringAnalysis
        }
        for result in results {
            guard let analysis = result.analysis else {
                failures += 1
                if let reason = result.errorMessage {
                    Log.preview.error("social audio analysis failed clip=\(result.request.clip.id): \(reason)")
                }
                continue
            }
            let role = result.request.role
            let target = role == .voice ? preset.voiceTargetLUFS : preset.musicTargetLUFS
            let peakCeiling = role == .voice
                ? preset.voicePeakCeilingDbFS
                : preset.musicPeakCeilingDbFS
            let gainDb = SocialAudioSettings.normalizationGainDb(
                measuredLUFS: analysis.integratedLoudnessLUFS,
                measuredPeakDbFS: analysis.samplePeakDBFS,
                targetLUFS: target,
                peakCeilingDbFS: peakCeiling
            )
            settingsById[result.request.clip.id] = SocialAudioSettings(
                role: role,
                preset: preset,
                measuredLoudnessLUFS: analysis.integratedLoudnessLUFS,
                measuredPeakDbFS: analysis.samplePeakDBFS,
                normalizationGainDb: gainDb,
                speechActivity: role == .voice ? result.speechActivity : [],
                duckingAmountDb: role == .music ? preset.musicDuckDb : 0
            )
        }
        guard !settingsById.isEmpty else { throw SocialAudioMixError.noReadableAudio }

        mutateClips(ids: Set(settingsById.keys), actionName: "Balance Audio for Social") { clip in
            if let settings = settingsById[clip.id] { clip.socialAudio = settings }
        }

        let voiceCount = settingsById.values.filter { $0.role == .voice }.count
        let musicCount = settingsById.values.filter { $0.role == .music }.count
        let skippedCount = failures
        let skipped = skippedCount == 0 ? "" : " · \(skippedCount) skipped"
        socialAudioMixMessage = "Balanced \(voiceCount) voice and \(musicCount) music clip\(musicCount == 1 ? "" : "s")\(skipped)."
    }

    /// Import one audio file, put it on a dedicated track from frame zero, and run the same
    /// balancing workflow used for existing project music.
    @discardableResult
    func addMusicAndBalance(from url: URL, preset: SocialAudioPreset? = nil) async throws -> String {
        guard ClipType(fileExtension: url.pathExtension.lowercased()) == .audio else {
            throw SocialAudioMixError.unsupportedMusicFile(url.lastPathComponent)
        }

        let standardized = url.standardizedFileURL
        let asset: MediaAsset
        if let existing = mediaAssets.first(where: { $0.url.standardizedFileURL == standardized }) {
            asset = existing
            if asset.duration <= 0 { await asset.loadMetadata() }
        } else {
            asset = MediaAsset(
                url: standardized,
                type: .audio,
                name: standardized.deletingPathExtension().lastPathComponent
            )
            await asset.loadMetadata()
            guard asset.duration.isFinite, asset.duration > 0 else {
                throw SocialAudioMixError.unreadableMusicFile(url.lastPathComponent)
            }
            importMediaAsset(asset)
            await finalizeImportedAsset(asset)
        }
        guard asset.duration.isFinite, asset.duration > 0 else {
            throw SocialAudioMixError.unreadableMusicFile(url.lastPathComponent)
        }

        // Match composition insertion's floor-to-frame rule so a non-frame-aligned
        // media duration never asks AVFoundation for a range just past EOF.
        let songFrames = max(1, secondsToFrame(seconds: asset.duration, fps: max(1, timeline.fps)))
        let duration = timeline.totalFrames > 0 ? min(songFrames, timeline.totalFrames) : songFrames
        var musicClipId: String?
        withTimelineSwap(actionName: "Add Music") {
            timeline.tracks.append(Track(type: .audio))
            let trackIndex = timeline.tracks.count - 1
            musicClipId = placeClip(
                asset: asset,
                trackIndex: trackIndex,
                startFrame: 0,
                durationFrames: duration,
                addLinkedAudio: false
            ).first
            if let musicClipId, let location = findClip(id: musicClipId) {
                timeline.tracks[location.trackIndex].clips[location.clipIndex].socialAudio = SocialAudioSettings(
                    role: .music,
                    preset: preset ?? socialAudioPreset,
                    duckingAmountDb: (preset ?? socialAudioPreset).musicDuckDb
                )
            }
        }
        guard let musicClipId else { throw SocialAudioMixError.unreadableMusicFile(url.lastPathComponent) }
        selectedClipIds = [musicClipId]
        try await balanceSocialAudio(preset: preset)
        return musicClipId
    }

    private func socialAudioRole(for clip: Clip) -> SocialAudioRole {
        if let role = clip.socialAudio?.role { return role }
        if clip.linkGroupId != nil || clip.sourceClipType == .video || clip.hasDenoiseEnabled {
            return .voice
        }
        return .music
    }

    /// Analysis can span cleanup generation and long media reads. Only apply a
    /// result if the exact clip, source resolution, and frame rate are unchanged.
    private func socialAudioRequestIsCurrent(_ request: SocialAudioAnalysisRequest) -> Bool {
        guard timeline.fps == request.fps,
              let location = findClip(id: request.clip.id) else { return false }
        let current = timeline.tracks[location.trackIndex].clips[location.clipIndex]
        guard current == request.clip,
              let currentURL = mediaResolver.resolveURL(for: current.mediaRef) else { return false }
        return currentURL.standardizedFileURL == request.sourceURL.standardizedFileURL
            && DiskCache.sizeMtimeTag(for: currentURL) == request.fileTag
    }
}
