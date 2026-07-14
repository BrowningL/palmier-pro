import Foundation
import Testing
@testable import PalmierPro

@Suite("Legacy project migration — real packages")
struct LegacyProjectMigrationIntegrationTests {
    private typealias JSONObject = [String: Any]

    private struct Coverage {
        var packages = 0
        var markers = 0
        var legacyVoiceCleanup = 0
        var socialAudio = 0
        var textStyles = 0
        var strokeObjects = 0
        var pillStyles = 0
        var effectTypes: Set<String> = []
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    private static var fixtureDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PALMIER_LEGACY_PROJECT_DIR"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Reads archived packages only; every migration and normalization step stays in memory.
    @Test(.enabled(if: fixtureDirectory != nil))
    func projectsDecodeMigrateAndStabilize() throws {
        guard let fixtureDirectory = Self.fixtureDirectory else { return }
        let projectURLs = try Self.projectJSONURLs(in: fixtureDirectory)
        var coverage = Coverage()

        for projectURL in projectURLs {
            let packageName = projectURL.deletingLastPathComponent().lastPathComponent
            let sourceData = try Data(contentsOf: projectURL)
            let rootObject = try JSONSerialization.jsonObject(with: sourceData)
            let rawTimelines = try Self.rawTimelines(from: rootObject, context: packageName)
            let migrated = try ProjectFile.decode(sourceData)

            guard migrated.timelines.count == rawTimelines.count else {
                throw FixtureError(description: "\(packageName): timeline count changed during decode")
            }

            coverage.packages += 1
            try Self.validateRawFeatures(
                rawTimelines,
                in: migrated,
                packageName: packageName,
                coverage: &coverage
            )

            let firstEncoding = try Self.sortedEncoding(migrated)
            let normalizedObject = try JSONSerialization.jsonObject(with: firstEncoding)
            #expect(
                !Self.containsKey("voiceCleanup", in: normalizedObject),
                "\(packageName): normalized project must not retain the legacy voiceCleanup field"
            )

            let reopened = try ProjectFile.decode(firstEncoding)
            let secondEncoding = try Self.sortedEncoding(reopened)
            #expect(firstEncoding == secondEncoding, "\(packageName): normalization must be idempotent")
            #expect(reopened.timelines == migrated.timelines, "\(packageName): timelines changed after reopen")
            #expect(reopened.activeTimelineId == migrated.activeTimelineId)
            #expect(reopened.openTimelineIds == migrated.openTimelineIds)
            #expect(reopened.viewStates == migrated.viewStates)
            #expect(reopened.multicamGroups == migrated.multicamGroups)
            let sourceDataAfterMigration = try Data(contentsOf: projectURL)
            #expect(sourceDataAfterMigration == sourceData, "\(packageName): source fixture must remain byte-identical")
        }

        #expect(coverage.packages >= 4, "The curated migration backup should contain all four projects")
        #expect(coverage.markers >= 54, "The fixture set must exercise legacy marker preservation")
        #expect(coverage.legacyVoiceCleanup >= 2, "The fixture set must exercise voiceCleanup migration")
        #expect(coverage.socialAudio >= 8, "The fixture set must exercise Social Audio persistence")
        #expect(coverage.textStyles >= 19, "The fixture set must exercise text-style persistence")
        #expect(coverage.strokeObjects >= 19, "The fixture set must exercise legacy stroke objects")
        #expect(coverage.pillStyles >= 15, "The fixture set must exercise fork pill-geometry migration")
        #expect(
            coverage.effectTypes.isSuperset(of: ["key.luma", "key.lumaDark", "key.person"]),
            "The fixture set must exercise every retained custom key effect"
        )
    }

    private static func validateRawFeatures(
        _ rawTimelines: [JSONObject],
        in project: ProjectFile,
        packageName: String,
        coverage: inout Coverage
    ) throws {
        for (timelineIndex, rawTimeline) in rawTimelines.enumerated() {
            let timeline = project.timelines[timelineIndex]
            let context = "\(packageName), timeline \(timelineIndex)"
            let rawMarkers = try objectArray(rawTimeline["markers"], defaultingToEmpty: true, context: "\(context) markers")
            guard timeline.markers.count == rawMarkers.count else {
                throw FixtureError(description: "\(context): marker count changed during decode")
            }
            coverage.markers += rawMarkers.count

            for (markerIndex, rawMarker) in rawMarkers.enumerated() {
                let actual = timeline.markers[markerIndex]
                var expected = try decode(TimelineMarker.self, object: rawMarker)
                if rawMarker["id"] == nil || rawMarker["id"] is NSNull { expected.id = actual.id }
                #expect(actual == expected, "\(context): marker \(markerIndex) changed during decode")
            }

            let rawTracks = try objectArray(rawTimeline["tracks"], defaultingToEmpty: false, context: "\(context) tracks")
            guard timeline.tracks.count == rawTracks.count else {
                throw FixtureError(description: "\(context): track count changed during decode")
            }

            for (trackIndex, rawTrack) in rawTracks.enumerated() {
                let track = timeline.tracks[trackIndex]
                let trackContext = "\(context), track \(trackIndex)"
                let rawClips = try objectArray(rawTrack["clips"], defaultingToEmpty: true, context: "\(trackContext) clips")
                guard track.clips.count == rawClips.count else {
                    throw FixtureError(description: "\(trackContext): clip count changed during decode")
                }

                for (clipIndex, rawClip) in rawClips.enumerated() {
                    try validateRawClip(
                        rawClip,
                        actual: track.clips[clipIndex],
                        context: "\(trackContext), clip \(clipIndex)",
                        coverage: &coverage
                    )
                }
            }
        }
    }

    private static func validateRawClip(
        _ rawClip: JSONObject,
        actual: Clip,
        context: String,
        coverage: inout Coverage
    ) throws {
        if let rawStyle = rawClip["textStyle"] as? JSONObject {
            coverage.textStyles += 1
            guard let actualStyle = actual.textStyle else {
                throw FixtureError(description: "\(context): text style was dropped during decode")
            }
            let expectedStyle = try decode(TextStyle.self, object: rawStyle)
            #expect(actualStyle == expectedStyle, "\(context): text style changed during decode")

            if let rawBackground = rawStyle["background"] as? JSONObject {
                let carriesForkGeometry = ["paddingH", "paddingV", "cornerRadius"].contains {
                    rawBackground.keys.contains($0)
                }
                let expectedShape = (rawBackground["shape"] as? String)
                    .flatMap { TextStyle.Background.Shape(rawValue: $0) }
                    ?? (carriesForkGeometry ? .pill : .box)
                if expectedShape == .pill { coverage.pillStyles += 1 }
                #expect(actualStyle.background.shape == expectedShape, "\(context): background shape migration changed")
            }

            if let rawStroke = rawStyle["border"] as? JSONObject {
                coverage.strokeObjects += 1
                let expectedWidth = number(rawStroke["width"]) ?? TextStyle.Stroke.legacyUpstreamWidth
                #expect(actualStyle.border.width == expectedWidth, "\(context): stroke width migration changed")
            }
        }

        if let rawSocialAudio = rawClip["socialAudio"] as? JSONObject {
            coverage.socialAudio += 1
            guard let actualSocialAudio = actual.socialAudio else {
                throw FixtureError(description: "\(context): Social Audio settings were dropped during decode")
            }
            let expectedSocialAudio = try decode(SocialAudioSettings.self, object: rawSocialAudio)
            #expect(actualSocialAudio == expectedSocialAudio, "\(context): Social Audio settings changed during decode")
        }

        let rawEffects = try objectArray(rawClip["effects"], defaultingToEmpty: true, context: "\(context) effects")
        let actualEffects = actual.effects ?? []
        for rawEffect in rawEffects {
            if let type = rawEffect["type"] as? String { coverage.effectTypes.insert(type) }
        }

        let rawDenoiseCount = rawEffects.count { ($0["type"] as? String) == Clip.denoiseEffectType }
        let rawVoiceCleanup = rawClip["voiceCleanup"] as? JSONObject
        if rawVoiceCleanup != nil { coverage.legacyVoiceCleanup += 1 }
        let shouldAppendDenoise = rawVoiceCleanup != nil && rawDenoiseCount == 0
        let expectedEffectCount = rawEffects.count + (shouldAppendDenoise ? 1 : 0)
        guard actualEffects.count == expectedEffectCount else {
            throw FixtureError(description: "\(context): effect count changed unexpectedly during decode")
        }

        for (effectIndex, rawEffect) in rawEffects.enumerated() {
            let actualEffect = actualEffects[effectIndex]
            var expectedEffect = try decode(Effect.self, object: rawEffect)
            if rawEffect["id"] == nil || rawEffect["id"] is NSNull { expectedEffect.id = actualEffect.id }
            #expect(actualEffect == expectedEffect, "\(context): effect \(effectIndex) changed during decode")
        }

        if shouldAppendDenoise, let rawVoiceCleanup {
            let denoise = actualEffects[rawEffects.count]
            let rawStrength = number(rawVoiceCleanup["strength"]) ?? 1
            let expectedStrength = rawStrength.isFinite ? min(1, max(0, rawStrength)) : 1
            #expect(denoise.type == Clip.denoiseEffectType, "\(context): voice cleanup did not migrate to denoise")
            #expect(denoise.enabled, "\(context): migrated denoise should remain enabled")
            #expect(denoise.params["amount"]?.value == expectedStrength, "\(context): denoise strength changed")
        }

        let expectedDenoiseCount = rawDenoiseCount + (shouldAppendDenoise ? 1 : 0)
        #expect(
            actualEffects.count { $0.type == Clip.denoiseEffectType } == expectedDenoiseCount,
            "\(context): denoise precedence created a duplicate or dropped an existing effect"
        )
    }

    private static func projectJSONURLs(in root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let packages: [URL]
        if root.pathExtension.caseInsensitiveCompare("palmier") == .orderedSame {
            packages = [root]
        } else {
            packages = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                guard url.pathExtension.caseInsensitiveCompare("palmier") == .orderedSame else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }

        let projectURLs = packages
            .map { $0.appendingPathComponent("project.json", isDirectory: false) }
            .filter { fileManager.isReadableFile(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        guard !projectURLs.isEmpty else {
            throw FixtureError(description: "No readable .palmier/project.json fixtures found under \(root.path)")
        }
        return projectURLs
    }

    private static func rawTimelines(from root: Any, context: String) throws -> [JSONObject] {
        guard let root = root as? JSONObject else {
            throw FixtureError(description: "\(context): project.json root is not an object")
        }
        if root["timelines"] != nil {
            return try objectArray(root["timelines"], defaultingToEmpty: false, context: "\(context) timelines")
        }
        return [root]
    }

    private static func objectArray(
        _ value: Any?,
        defaultingToEmpty: Bool,
        context: String
    ) throws -> [JSONObject] {
        if value == nil || value is NSNull {
            if defaultingToEmpty { return [] }
            throw FixtureError(description: "\(context): required array is missing")
        }
        guard let values = value as? [Any] else {
            throw FixtureError(description: "\(context): expected an array")
        }
        return try values.enumerated().map { index, value in
            guard let object = value as? JSONObject else {
                throw FixtureError(description: "\(context)[\(index)]: expected an object")
            }
            return object
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, object: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func sortedEncoding(_ project: ProjectFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func containsKey(_ key: String, in value: Any) -> Bool {
        if let object = value as? JSONObject {
            return object[key] != nil || object.values.contains { containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }
}
