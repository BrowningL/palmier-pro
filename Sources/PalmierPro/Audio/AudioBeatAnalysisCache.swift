import Foundation

struct AudioBeatAnalysisCacheKey: Hashable, Sendable {
    let detectorVersion: Int
    let sourcePath: String
    let sourceFileSize: UInt64
    let sourceModificationTime: TimeInterval
    let rangeStart: Double
    let rangeEnd: Double
    let minimumBPM: Double
    let maximumBPM: Double
    let bpmOverride: Double?
}

/// Small process-local LRU. Changing only marker cadence (every beat / every 2 /
/// every 4) can then reuse the expensive decode + FFT result immediately.
actor AudioBeatAnalysisCache {
    static let shared = AudioBeatAnalysisCache()

    private struct Entry {
        let analysis: AudioBeatAnalysis
        var access: UInt64
    }

    private let capacity = 8
    private var clock: UInt64 = 0
    private var entries: [AudioBeatAnalysisCacheKey: Entry] = [:]

    func value(for key: AudioBeatAnalysisCacheKey) -> AudioBeatAnalysis? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.analysis
    }

    func insert(_ analysis: AudioBeatAnalysis, for key: AudioBeatAnalysisCacheKey) {
        clock &+= 1
        entries[key] = Entry(analysis: analysis, access: clock)
        if entries.count > capacity,
           let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
