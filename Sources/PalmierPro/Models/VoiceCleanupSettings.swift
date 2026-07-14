import Foundation

struct VoiceCleanupSettings: Codable, Sendable, Equatable {
    static let defaultStrength = 1.0

    var strength: Double

    init(strength: Double = defaultStrength) {
        self.strength = Self.clamp(strength)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(strength: (try? container.decode(Double.self, forKey: .strength)) ?? Self.defaultStrength)
    }

    var normalizedStrength: Double { Self.clamp(strength) }

    private enum CodingKeys: String, CodingKey {
        case strength
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultStrength }
        return min(1, max(0, value))
    }
}
