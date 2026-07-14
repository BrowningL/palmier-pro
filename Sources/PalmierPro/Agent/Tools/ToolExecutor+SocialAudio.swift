import Foundation

extension ToolExecutor {
    fileprivate struct BalanceSocialAudioInput: DecodableToolArgs {
        enum Action: String, Decodable { case balance, clear }

        struct RoleOverride: Decodable {
            let clipId: String
            let role: SocialAudioRole
        }

        let action: Action?
        let preset: SocialAudioPreset?
        let roles: [RoleOverride]?
        let clipIds: [String]?

        static let allowedKeys: Set<String> = ["action", "preset", "roles", "clipIds"]
    }

    func balanceSocialAudio(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) async throws -> ToolResult {
        let input: BalanceSocialAudioInput = try decodeToolArgs(
            args,
            path: "balance_social_audio"
        )
        switch input.action ?? .balance {
        case .clear:
            guard input.preset == nil, input.roles == nil else {
                throw ToolError("preset and roles are only valid for action='balance'.")
            }
            guard let clipIds = input.clipIds, !clipIds.isEmpty else {
                throw ToolError("clipIds is required and cannot be empty for action='clear'.")
            }
            try validateAudioClipIds(clipIds, editor: editor)
            let snapshot = timelineSnapshot(editor)
            editor.clearSocialAudioMix(clipIds: clipIds)
            return mutationResult(
                editor,
                since: snapshot,
                touched: clipIds,
                extra: ["action": "clear"]
            )

        case .balance:
            guard input.clipIds == nil else {
                throw ToolError("clipIds is only valid for action='clear'; balance analyzes all audio in the active timeline.")
            }
            var roleOverrides: [String: SocialAudioRole] = [:]
            for entry in input.roles ?? [] {
                guard roleOverrides[entry.clipId] == nil else {
                    throw ToolError("roles contains duplicate clipId: \(entry.clipId)")
                }
                try validateAudioClipIds([entry.clipId], editor: editor)
                roleOverrides[entry.clipId] = entry.role
            }

            let snapshot = timelineSnapshot(editor)
            try await editor.balanceSocialAudio(
                preset: input.preset,
                roleOverrides: roleOverrides
            )
            let audioIds = editor.timeline.tracks
                .flatMap(\.clips)
                .filter { $0.mediaType == .audio }
                .map(\.id)
            return mutationResult(
                editor,
                since: snapshot,
                touched: audioIds,
                extra: [
                    "action": "balance",
                    "preset": editor.socialAudioPreset.rawValue,
                ],
                notes: editor.socialAudioMixMessage.map { [$0] } ?? []
            )
        }
    }

    private func validateAudioClipIds(_ clipIds: [String], editor: EditorViewModel) throws {
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else {
                throw ToolError("Clip not found: \(id)")
            }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; balance_social_audio needs audio clips.")
            }
        }
    }
}
