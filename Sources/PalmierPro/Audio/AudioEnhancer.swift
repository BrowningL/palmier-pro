import AVFoundation
#if BUNDLED_SPEECH
import SpeechEnhancement
#endif

enum AudioEnhancer {
    static let cache = DiskCache(named: "EnhancedAudio")

    enum EnhanceError: LocalizedError {
        case noAudioTrack
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "Source has no audio track"
            case .writeFailed: "Could not write enhanced audio"
            }
        }
    }

    static func denoisedAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        let outputURL = denoisedURL(for: sourceURL, mediaRef: mediaRef)
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
        #if BUNDLED_SPEECH
        return try await bakeCoordinator.run(key: outputURL) {
            if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
            return try await bakeDenoisedAudio(
                sourceURL: sourceURL,
                mediaRef: mediaRef,
                outputURL: outputURL
            )
        }
        #else
        throw MLXRuntime.Unavailable()
        #endif
    }

    #if BUNDLED_SPEECH
    private static func bakeDenoisedAudio(
        sourceURL: URL,
        mediaRef: String,
        outputURL: URL
    ) async throws -> URL {
        try await bakeGate.wait()
        defer { Task { await bakeGate.signal() } }
        var decoded = try await readChannels(from: sourceURL)
        guard decoded.channels.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }
        let dryFrameCounts = decoded.channels.map(\.count)
        var wet: [[Float]] = []
        for ch in decoded.channels.indices {
            wet.append(try await modelBox.enhance(
                audio: decoded.channels[ch],
                sampleRate: SpeechEnhancer.sampleRate
            ))
            decoded.channels[ch] = []
        }
        wet = try alignedWetChannels(wet, dryFrameCounts: dryFrameCounts)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        try write(
            channels: wet,
            leadingSilenceFrames: decoded.leadingSilenceFrames,
            to: outputURL
        )
        let expectedFrames = expectedOutputFrameCount(
            decodedFrameCount: dryFrameCounts[0],
            leadingSilenceFrames: decoded.leadingSilenceFrames
        )
        guard (try? AVAudioFile(forReading: outputURL).length) == AVAudioFramePosition(expectedFrames) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw EnhanceError.writeFailed
        }
        return outputURL
    }
    #endif

    static func cachedDenoisedURL(for sourceURL: URL, mediaRef: String) -> URL? {
        let url = denoisedURL(for: sourceURL, mediaRef: mediaRef)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func denoisedURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_wet-v2.caf")
    }

    static func alignedWetChannels(
        _ channels: [[Float]],
        dryFrameCounts: [Int]
    ) throws -> [[Float]] {
        guard channels.count == dryFrameCounts.count,
              !channels.isEmpty,
              dryFrameCounts.allSatisfy({ $0 > 0 }) else {
            throw EnhanceError.writeFailed
        }
        return zip(channels, dryFrameCounts).map { channel, expectedCount in
            if channel.count == expectedCount { return channel }
            if channel.count > expectedCount { return Array(channel.prefix(expectedCount)) }
            return channel + repeatElement(0, count: expectedCount - channel.count)
        }
    }

    static func expectedOutputFrameCount(
        decodedFrameCount: Int,
        leadingSilenceFrames: Int
    ) -> Int {
        max(0, decodedFrameCount) + max(0, leadingSilenceFrames)
    }

    #if BUNDLED_SPEECH
    private static let bakeGate = AsyncSemaphore(value: 2)
    private static let bakeCoordinator = BakeCoordinator()
    private static let modelBox = ModelBox()

    private actor BakeCoordinator {
        private var tasks: [URL: Task<URL, Error>] = [:]

        func run(
            key: URL,
            operation: @Sendable @escaping () async throws -> URL
        ) async throws -> URL {
            if let task = tasks[key] { return try await task.value }
            let task = Task(priority: .utility) { try await operation() }
            tasks[key] = task
            defer { tasks.removeValue(forKey: key) }
            return try await task.value
        }
    }

    private actor ModelBox {
        private var enhancer: SpeechEnhancer?

        func enhance(audio: [Float], sampleRate: Int) async throws -> [Float] {
            if enhancer == nil { enhancer = try await SpeechEnhancer.fromPretrained() }
            return try enhancer!.enhanceChunked(audio: audio, sampleRate: sampleRate)
        }
    }

    private static var sampleRate: Double { Double(SpeechEnhancer.sampleRate) }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Reading

    private struct DecodedAudio {
        var channels: [[Float]]
        let leadingSilenceFrames: Int
    }

    private static func readChannels(from url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first
        let desc = try await track?.load(.formatDescriptions).first
        let sourceChannels = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let count = min(2, max(1, Int(sourceChannels)))
        var channels = [[Float]](repeating: [], count: count)
        let timing = try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: count,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ]
        ) { buffer in
            guard let data = buffer.floatChannelData else { return }
            for ch in 0..<count {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
        }
        let firstPresentation = max(0, timing.firstPresentationSeconds ?? 0)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil }
        let boundedPresentation = min(firstPresentation, duration ?? 3_600)
        return DecodedAudio(
            channels: channels,
            leadingSilenceFrames: Int((boundedPresentation * sampleRate).rounded())
        )
    }

    // MARK: - Writing

    private static func write(
        channels: [[Float]],
        leadingSilenceFrames: Int,
        to outputURL: URL
    ) throws {
        guard let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount }),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw EnhanceError.writeFailed }
        outBuffer.frameLength = AVAudioFrameCount(frameCount)
        for ch in channels.indices {
            channels[ch].withUnsafeBufferPointer { src in
                outBuffer.floatChannelData?[ch].update(from: src.baseAddress!, count: frameCount)
            }
        }

        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID().uuidString).caf")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        if leadingSilenceFrames > 0,
           let silence = AVAudioPCMBuffer(
               pcmFormat: format,
               frameCapacity: AVAudioFrameCount(min(65_536, leadingSilenceFrames))
           ) {
            var remaining = leadingSilenceFrames
            while remaining > 0 {
                let count = min(Int(silence.frameCapacity), remaining)
                silence.frameLength = AVAudioFrameCount(count)
                for channel in 0..<channels.count {
                    silence.floatChannelData?[channel].initialize(repeating: 0, count: count)
                }
                try file.write(from: silence)
                remaining -= count
            }
        }
        try file.write(from: outBuffer)
        try FileIO.moveReplacingDestination(from: tempURL, to: outputURL)
    }
    #endif
}
