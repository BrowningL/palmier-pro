import Foundation

enum SocialAudioRole: String, Codable, Sendable, Equatable, CaseIterable {
    case voice
    case music

    var displayName: String {
        switch self {
        case .voice: "Voice"
        case .music: "Music"
        }
    }
}

enum SocialAudioPreset: String, Codable, Sendable, Equatable, CaseIterable {
    case balanced
    case clearVoice
    case fixedLevel

    var displayName: String {
        switch self {
        case .balanced: "Balanced (Ducking)"
        case .clearVoice: "Clear Voice (Ducking)"
        case .fixedLevel: "Fixed Level (No Ducking)"
        }
    }

    var voiceTargetLUFS: Double { -16 }
    var musicTargetLUFS: Double {
        switch self {
        case .balanced: -18
        case .clearVoice: -20
        case .fixedLevel: -30
        }
    }
    var musicDuckDb: Double {
        switch self {
        case .balanced: 14
        case .clearVoice: 18
        case .fixedLevel: 0
        }
    }
    var usesSpeechDucking: Bool { musicDuckDb > 0 }
    var voicePeakCeilingDbFS: Double { -3 }
    var musicPeakCeilingDbFS: Double { -5 }
}

/// A detected spoken interval in the source file's presentation timeline.
/// Source time makes the interval survive timeline moves, trims, speed changes, and clip splits.
struct SocialAudioActivityRange: Codable, Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double

    init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = max(0, startSeconds.isFinite ? startSeconds : 0)
        self.endSeconds = max(self.startSeconds, endSeconds.isFinite ? endSeconds : self.startSeconds)
    }
}

/// Persisted, non-destructive recipe produced by Social Audio Mix.
/// Authored volume, fades, and keyframes remain independent and are multiplied at render time.
struct SocialAudioSettings: Codable, Sendable, Equatable {
    var role: SocialAudioRole
    var preset: SocialAudioPreset
    var measuredLoudnessLUFS: Double?
    var measuredPeakDbFS: Double?
    var normalizationGainDb: Double
    var speechActivity: [SocialAudioActivityRange]
    var duckingAmountDb: Double

    init(
        role: SocialAudioRole,
        preset: SocialAudioPreset = .balanced,
        measuredLoudnessLUFS: Double? = nil,
        measuredPeakDbFS: Double? = nil,
        normalizationGainDb: Double = 0,
        speechActivity: [SocialAudioActivityRange] = [],
        duckingAmountDb: Double = 0
    ) {
        self.role = role
        self.preset = preset
        self.measuredLoudnessLUFS = Self.finite(measuredLoudnessLUFS)
        self.measuredPeakDbFS = Self.finite(measuredPeakDbFS)
        self.normalizationGainDb = Self.clampGain(normalizationGainDb)
        self.speechActivity = speechActivity
        self.duckingAmountDb = max(0, min(30, duckingAmountDb.isFinite ? duckingAmountDb : 0))
    }

    var normalizationGain: Double {
        pow(10, normalizationGainDb / 20)
    }

    static func normalizationGainDb(
        measuredLUFS: Double?,
        measuredPeakDbFS: Double?,
        targetLUFS: Double,
        peakCeilingDbFS: Double
    ) -> Double {
        guard let measuredLUFS, measuredLUFS.isFinite else { return 0 }
        var gain = targetLUFS - measuredLUFS
        if let measuredPeakDbFS, measuredPeakDbFS.isFinite {
            gain = min(gain, peakCeilingDbFS - measuredPeakDbFS)
        }
        return clampGain(gain)
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(12, max(-24, value))
    }
}
