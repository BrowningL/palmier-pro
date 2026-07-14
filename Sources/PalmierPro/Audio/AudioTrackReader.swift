import AVFoundation
import Foundation

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    // CoreMedia decoders are the scarce resource shared by waveform, sync,
    // loudness, and beat analysis. Gate at the common boundary so concurrent
    // features cannot each open their own independent decoder pool.
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
        /// Presentation time of the first decoded PCM sample in the asset timeline.
        /// This can differ from the requested range for AAC priming/edit lists.
        let firstPresentationSeconds: Double?
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

        var firstPresentationSeconds: Double?
        while let sample = output.copyNextSampleBuffer() {
            if firstPresentationSeconds == nil {
                let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
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
