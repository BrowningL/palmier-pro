import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

actor VoiceCleanupCache {
    static let shared = VoiceCleanupCache()

    private static let renderGate = AsyncSemaphore(value: 1)
    private var inFlight: [String: Task<URL, Error>] = [:]

    func processedURL(sourceURL: URL, strength: Double) async throws -> URL {
        let normalizedStrength = VoiceCleanupSettings(strength: strength).normalizedStrength
        guard normalizedStrength > 0 else { return sourceURL }

        let key = try Self.cacheKey(sourceURL: sourceURL, strength: strength)
        let destination = try Self.cacheDirectory()
            .appendingPathComponent(key)
            .appendingPathExtension("caf")

        if Self.isUsableCacheFile(destination) { return destination }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        if let task = inFlight[key] { return try await task.value }

        let task = Task.detached(priority: .userInitiated) {
            try await Self.renderGate.wait()
            defer { Task { await Self.renderGate.signal() } }
            return try VoiceCleanupRenderer.render(
                sourceURL: sourceURL,
                destinationURL: destination,
                strength: strength
            )
        }
        inFlight[key] = task
        do {
            let url = try await task.value
            inFlight[key] = nil
            return url
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private static func cacheKey(sourceURL: URL, strength: Double) throws -> String {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let normalizedStrength = VoiceCleanupSettings(strength: strength).normalizedStrength
        let fingerprint = [
            "voice-cleanup-v1",
            sourceURL.standardizedFileURL.path,
            String(size),
            String(format: "%.6f", modified),
            String(normalizedStrength.bitPattern, radix: 16),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro", isDirectory: true)
            .appendingPathComponent("VoiceCleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func isUsableCacheFile(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 512,
              let audioFile = try? AVAudioFile(forReading: url) else { return false }
        return audioFile.length > 0
    }
}

enum VoiceCleanupRenderer {
    enum RenderError: LocalizedError {
        case invalidSource
        case audioUnitSetup(OSStatus)
        case bufferAllocation
        case renderFailed
        case incompleteRender(expected: AVAudioFramePosition, actual: AVAudioFramePosition)

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                "The source has no readable audio samples."
            case .audioUnitSetup(let status):
                "Voice isolation could not be configured (status \(status))."
            case .bufferAllocation:
                "Voice isolation could not allocate audio buffers."
            case .renderFailed:
                "Voice isolation stopped while rendering."
            case .incompleteRender(let expected, let actual):
                "Voice isolation rendered \(actual) of \(expected) samples."
            }
        }
    }

    private static let maximumFrames: AVAudioFrameCount = 4096
    private static let warmupSeconds = 0.25

    @discardableResult
    static func render(sourceURL: URL, destinationURL: URL, strength: Double) throws -> URL {
        let started = ContinuousClock.now
        let source = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = source.processingFormat
        guard source.length > 0, sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sourceFormat.sampleRate,
                channels: sourceFormat.channelCount
              ) else {
            throw RenderError.invalidSource
        }

        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        try setParameter(
            kAUSoundIsolationParam_SoundToIsolate,
            value: Float(kAUSoundIsolationSoundType_HighQualityVoice),
            on: effect.audioUnit
        )
        try setParameter(
            kAUSoundIsolationParam_WetDryMixPercent,
            value: Float(VoiceCleanupSettings(strength: strength).normalizedStrength * 100),
            on: effect.audioUnit
        )

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: maximumFrames
        )

        let sourceFrames = source.length
        let warmupFrames = AVAudioFramePosition((format.sampleRate * warmupSeconds).rounded())
        try engine.start()
        let latencyFrames = AVAudioFramePosition((effect.auAudioUnit.latency * format.sampleRate).rounded())
        let tailFrames = AVAudioFramePosition((effect.auAudioUnit.tailTime * format.sampleRate).rounded(.up))
        let flushFramePosition = max(
            AVAudioFramePosition(maximumFrames),
            latencyFrames + tailFrames + AVAudioFramePosition(maximumFrames)
        )
        guard flushFramePosition <= AVAudioFramePosition(UInt32.max),
              let flushBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(flushFramePosition)
              ),
              let flushChannels = flushBuffer.floatChannelData else {
            throw RenderError.bufferAllocation
        }
        flushBuffer.frameLength = AVAudioFrameCount(flushFramePosition)
        for channel in 0..<Int(format.channelCount) {
            flushChannels[channel].initialize(repeating: 0, count: Int(flushFramePosition))
        }

        player.scheduleSegment(
            source,
            startingFrame: 0,
            frameCount: AVAudioFrameCount(sourceFrames),
            at: AVAudioTime(sampleTime: warmupFrames, atRate: format.sampleRate)
        )
        // Keep the input node alive beyond EOF so Sound Isolation can flush its
        // lookahead instead of replacing the final speech samples with silence.
        player.scheduleBuffer(
            flushBuffer,
            at: AVAudioTime(
                sampleTime: warmupFrames + sourceFrames,
                atRate: format.sampleRate
            )
        )

        let skipFrames = warmupFrames + latencyFrames
        let totalFrames = skipFrames + sourceFrames
        player.play()

        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp.caf")
        try? FileManager.default.removeItem(at: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitDepthHintKey: 24,
        ]
        var output: AVAudioFile? = try AVAudioFile(forWriting: temporaryURL, settings: outputSettings)
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
            throw RenderError.bufferAllocation
        }

        var rendered: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        var contextRetries = 0
        while rendered < totalFrames {
            try Task.checkCancellation()
            let request = AVAudioFrameCount(min(
                AVAudioFramePosition(maximumFrames),
                totalFrames - rendered
            ))
            switch try engine.renderOffline(request, to: renderBuffer) {
            case .success:
                contextRetries = 0
                let count = AVAudioFramePosition(renderBuffer.frameLength)
                guard count > 0 else { throw RenderError.renderFailed }
                let begin = max(0, skipFrames - rendered)
                let available = max(0, count - begin)
                let take = min(available, sourceFrames - written)
                if take > 0 {
                    try copy(
                        from: renderBuffer,
                        sourceOffset: Int(begin),
                        frameCount: Int(take),
                        to: writeBuffer
                    )
                    try output?.write(from: writeBuffer)
                    written += take
                }
                rendered += count
            case .cannotDoInCurrentContext:
                contextRetries += 1
                guard contextRetries < 100 else { throw RenderError.renderFailed }
            case .insufficientDataFromInputNode, .error:
                throw RenderError.renderFailed
            @unknown default:
                throw RenderError.renderFailed
            }
        }

        player.stop()
        engine.stop()
        output = nil
        guard written == sourceFrames else {
            throw RenderError.incompleteRender(expected: sourceFrames, actual: written)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
        let elapsed = started.duration(to: .now)
        Log.preview.info(
            "voice cleanup rendered file=\(sourceURL.lastPathComponent) frames=\(sourceFrames) "
                + "channels=\(format.channelCount) strength=\(String(format: "%.2f", strength)) "
                + "elapsed=\(elapsed)"
        )
        return destinationURL
    }

    private static func setParameter(
        _ parameter: AudioUnitParameterID,
        value: AudioUnitParameterValue,
        on audioUnit: AudioUnit
    ) throws {
        let status = AudioUnitSetParameter(
            audioUnit,
            parameter,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
        guard status == noErr else { throw RenderError.audioUnitSetup(status) }
    }

    private static func copy(
        from source: AVAudioPCMBuffer,
        sourceOffset: Int,
        frameCount: Int,
        to destination: AVAudioPCMBuffer
    ) throws {
        guard let sourceChannels = source.floatChannelData,
              let destinationChannels = destination.floatChannelData else {
            throw RenderError.bufferAllocation
        }
        destination.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(source.format.channelCount) {
            destinationChannels[channel].update(
                from: sourceChannels[channel].advanced(by: sourceOffset),
                count: frameCount
            )
        }
    }
}
