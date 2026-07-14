import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InspectorView {

    @ViewBuilder
    func audioTabContent() -> some View {
        let audios = selectedAudioClips
        let single = audios.count == 1 ? audios.first : nil
        let kfVisible = single != nil && editor.keyframesPanelVisible

        if let clip = single, kfVisible {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    // Match the kf panel's ruler+strip header height so Volume aligns with its lane.
                    sectionTitleLabel(title: "Levels")
                        .frame(height: KeyframesMetrics.headerHeight, alignment: .bottomLeading)
                    volumeRow(audios: audios)
                    fadeRow(label: "Fade In", clips: audios, edge: .left)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                    fadeRow(label: "Fade Out", clips: audios, edge: .right)
                        .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                    voiceCleanupSection(audios: audios)
                        .padding(.top, AppTheme.Spacing.md)
                    socialAudioSection(audios: audios)
                        .padding(.top, AppTheme.Spacing.md)
                    if nonTextVisualClips.isEmpty {
                        speedSection(clips: audios)
                            .padding(.trailing, KeyframesMetrics.controlsColumnWidth + AppTheme.Spacing.sm)
                            .padding(.top, AppTheme.Spacing.md)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppTheme.Spacing.sm)
                Divider()
                KeyframesPanel(clip: clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, AppTheme.Spacing.sm)
            }
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    sectionTitleLabel(title: "Levels")
                    volumeRow(audios: audios)
                    fadeRow(label: "Fade In", clips: audios, edge: .left)
                    fadeRow(label: "Fade Out", clips: audios, edge: .right)
                }
                voiceCleanupSection(audios: audios)
                socialAudioSection(audios: audios)
                if nonTextVisualClips.isEmpty {
                    speedSection(clips: audios)
                }
            }
        }

        keyframesToggleBar(enabled: single != nil)
    }

    @ViewBuilder
    private func socialAudioSection(audios: [Clip]) -> some View {
        let explicitRoles = audios.compactMap { $0.socialAudio?.role }
        let roles = Set(explicitRoles)
        let role = roles.count == 1 && explicitRoles.count == audios.count ? roles.first : nil
        let singleSettings = audios.count == 1 ? audios.first?.socialAudio : nil
        let usesSpeechDucking = editor.socialAudioPreset.usesSpeechDucking

        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack {
                sectionTitleLabel(title: "Social Audio Mix")
                Spacer()
                if audios.contains(where: { $0.socialAudio != nil }) {
                    Button("Reset") { editor.clearSocialAudioMix(clipIds: audios.map(\.id)) }
                        .font(.system(size: AppTheme.FontSize.xs))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            propertyRow(label: "Selected audio") {
                Menu {
                    ForEach(SocialAudioRole.allCases, id: \.rawValue) { candidate in
                        Button {
                            editor.setSocialAudioRole(clipIds: audios.map(\.id), role: candidate)
                        } label: {
                            if role == candidate {
                                Label(candidate.displayName, systemImage: "checkmark")
                            } else {
                                Text(candidate.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(role?.displayName ?? "Auto")
                        Image(systemName: "chevron.down")
                            .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            .frame(height: KeyframesMetrics.rowHeight)

            propertyRow(label: "Preset") {
                Picker("Preset", selection: Binding(
                    get: { editor.socialAudioPreset },
                    set: { editor.socialAudioPreset = $0 }
                )) {
                    ForEach(SocialAudioPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .frame(height: KeyframesMetrics.rowHeight)

            HStack(spacing: AppTheme.Spacing.sm) {
                Button {
                    chooseSocialMusic()
                } label: {
                    Label("Add Music…", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    Task { @MainActor in
                        do {
                            try await editor.balanceSocialAudio()
                        } catch {
                            editor.socialAudioMixMessage = error.localizedDescription
                        }
                    }
                } label: {
                    if editor.isSocialAudioMixing {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("Balance", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(editor.isSocialAudioMixing)
            .help(usesSpeechDucking
                ? "Measure the cleaned voice, normalize it, then duck music during speech"
                : "Measure and normalize the cleaned voice and music to steady levels without ducking")

            if let settings = singleSettings {
                Text(socialAudioResult(settings))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = editor.socialAudioMixMessage {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(usesSpeechDucking
                    ? "Voice Cleanup → −16 LUFS voice → speech-aware music ducking"
                    : "Voice Cleanup → −16 LUFS voice → steady −30 LUFS music (no ducking)")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
    }

    private func socialAudioResult(_ settings: SocialAudioSettings) -> String {
        guard let measured = settings.measuredLoudnessLUFS else {
            return "\(settings.role.displayName) · not measured yet"
        }
        let target = settings.role == .voice
            ? settings.preset.voiceTargetLUFS
            : settings.preset.musicTargetLUFS
        let sign = settings.normalizationGainDb >= 0 ? "+" : ""
        return String(
            format: "%@ · %.1f → %.0f LUFS · %@%.1f dB",
            settings.role.displayName,
            measured,
            target,
            sign,
            settings.normalizationGainDb
        )
    }

    private func chooseSocialMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the song you want beneath your voice"
        panel.allowedContentTypes = [.audio]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await editor.addMusicAndBalance(from: url)
                } catch {
                    editor.socialAudioMixMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func voiceCleanupSection(audios: [Clip]) -> some View {
        let enabled = sharedClipValue(audios) { $0.voiceCleanup != nil }
        let showsStrength = audios.contains { $0.voiceCleanup != nil }

        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionTitleLabel(title: "Voice Cleanup")
            propertyRow(label: "Remove Noise") {
                Toggle("", isOn: Binding(
                    get: { enabled ?? false },
                    set: { editor.setVoiceCleanup(clipIds: audios.map(\.id), enabled: $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Isolate spoken voice and suppress background sound")
            }
            .frame(height: KeyframesMetrics.rowHeight)

            if showsStrength {
                propertyRow(label: "Strength") {
                    ScrubbableNumberField(
                        value: sharedClipValue(audios) { $0.voiceCleanup?.normalizedStrength ?? 0 },
                        range: 0...1,
                        displayMultiplier: 100,
                        format: "%.0f",
                        valueSuffix: "%",
                        fieldWidth: 56,
                        onChanged: {
                            editor.applyVoiceCleanupStrength(clipIds: audios.map(\.id), strength: $0)
                        }
                    ) {
                        editor.commitVoiceCleanupStrength(clipIds: audios.map(\.id), strength: $0)
                    }
                }
                .frame(height: KeyframesMetrics.rowHeight)
            }

            Text("High Quality Voice · On-device")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
    }

    @ViewBuilder
    private func volumeRow(audios: [Clip]) -> some View {
        let single = audios.count == 1 ? audios.first : nil
        animatableRow(label: "Volume", clipId: single?.id, property: .volume) {
            ScrubbableNumberField(
                value: sharedClipValue(audios) { clip in
                    clip.liveVolumeKfDb(at: editor.activeFrame) ?? VolumeScale.dbFromLinear(clip.volume)
                },
                range: VolumeScale.floorDb...VolumeScale.ceilingDb,
                format: "%.1f",
                valueSuffix: " dB",
                dragSensitivity: 0.3,
                fieldWidth: 56,
                displayTextOverride: { db in db <= VolumeScale.floorDb ? "-∞ dB" : nil },
                onChanged: { db in
                    for c in audios { editor.applyVolume(clipId: c.id, valueDb: db) }
                }
            ) { db in
                commitToClips(audios, actionName: "Change Volume") { c in
                    editor.commitVolume(clipId: c.id, valueDb: db)
                }
            }
        }
    }

    @ViewBuilder
    private func fadeRow(label: String, clips: [Clip], edge: FadeEdge) -> some View {
        let fps = Double(max(1, editor.timeline.fps))
        let single = clips.count == 1 ? clips.first : nil
        let maxSeconds = single.map { Double($0.durationFrames) / fps } ?? 60.0
        let actionName = edge == .left ? "Change Fade In" : "Change Fade Out"
        propertyRow(label: label) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { clip in
                    Double(clip.fadeFrames(edge)) / fps
                },
                range: 0...maxSeconds,
                format: "%.2f",
                valueSuffix: " s",
                dragSensitivity: 0.02,
                fieldWidth: 56,
                onChanged: { seconds in
                    let frames = Int((seconds * fps).rounded())
                    for c in clips { editor.applyFade(clipId: c.id, edge: edge, frames: frames) }
                }
            ) { seconds in
                let frames = Int((seconds * fps).rounded())
                commitToClips(clips, actionName: actionName) { c in
                    editor.commitFade(clipId: c.id, edge: edge, frames: frames)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }
}
