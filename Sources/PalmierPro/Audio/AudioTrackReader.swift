import AVFoundation
import Foundation

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    private static let decoderGate = AsyncSemaphore(value: 2)

    enum ReadError: Error {
        case noAudioTrack(String)
        case readFailed(String)

        var message: String {
            switch self {
            case .noAudioTrack(let name): "No audio track in \(name)"
            case .readFailed(let reason): reason
            }
        }
    }

    struct ReadTiming: Sendable, Equatable {
        let firstPresentationSeconds: Double?
    }

    struct MixSource: Sendable {
        let url: URL
        let gain: Float
    }

    /// Whole-range mono Float32 decode at `sampleRate`
    static func readMonoFloats(from url: URL, sampleRate: Double, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        var samples: [Float] = []
        try await read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ], range: range) { buffer in
            guard let data = buffer.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Decode `url`'s first audio track with `outputSettings` (and optional `range`),
    /// invoking `onBuffer` for each PCM buffer. Throws `ReadError` on any failure.
    @discardableResult
    static func read(
        from url: URL,
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws -> ReadTiming {
        try await decoderGate.wait()
        defer { Task { await decoderGate.signal() } }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        return try stream(reader: reader, output: output, onBuffer: onBuffer)
    }

    /// Decodes an AVFoundation mix of aligned sources. Using AudioMixOutput keeps
    /// dry/wet measurement streaming instead of retaining two full PCM files.
    @discardableResult
    static func readMix(
        sources: [MixSource],
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws -> ReadTiming {
        try await decoderGate.wait()
        defer { Task { await decoderGate.signal() } }

        let composition = AVMutableComposition()
        var compositionTracks: [AVMutableCompositionTrack] = []
        var inputParameters: [AVMutableAudioMixInputParameters] = []
        for source in sources where source.gain > 0 {
            let asset = AVURLAsset(url: source.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                      withMediaType: .audio,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                throw ReadError.noAudioTrack(source.url.lastPathComponent)
            }
            let assetDuration = try await asset.load(.duration)
            let trackRange = try await sourceTrack.load(.timeRange)
            let readableRange = CMTimeRangeGetIntersection(
                trackRange,
                otherRange: CMTimeRange(start: .zero, duration: assetDuration)
            )
            guard readableRange.duration > .zero else {
                throw ReadError.noAudioTrack(source.url.lastPathComponent)
            }
            do {
                try compositionTrack.insertTimeRange(
                    readableRange,
                    of: sourceTrack,
                    at: readableRange.start
                )
            } catch {
                throw ReadError.readFailed(error.localizedDescription)
            }
            let parameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            parameters.setVolume(source.gain, at: .zero)
            compositionTracks.append(compositionTrack)
            inputParameters.append(parameters)
        }
        guard !compositionTracks.isEmpty else {
            throw ReadError.readFailed("The audio mix has no audible sources")
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: composition) } catch {
            throw ReadError.readFailed(error.localizedDescription)
        }
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: compositionTracks,
            audioSettings: outputSettings
        )
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        output.audioMix = audioMix
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read the aligned audio mix")
        }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }
        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        return try stream(reader: reader, output: output, onBuffer: onBuffer)
    }

    private static func stream(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) throws -> ReadTiming {
        var firstPresentationSeconds: Double?
        while let sample = output.copyNextSampleBuffer() {
            if firstPresentationSeconds == nil {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if seconds.isFinite { firstPresentationSeconds = seconds }
            }
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            try onBuffer(pcm)
        }

        if reader.status == .failed {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
        return ReadTiming(firstPresentationSeconds: firstPresentationSeconds)
    }
}
