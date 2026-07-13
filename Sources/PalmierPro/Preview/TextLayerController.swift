import AVFoundation
import AppKit
import QuartzCore

/// Preview owns a long-lived `CATextLayer` tree with imperative opacity;
/// export hands a one-shot tree to `AVVideoCompositionCoreAnimationTool`.
@MainActor
final class TextLayerController {

    let textRoot: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.isGeometryFlipped = true
        return layer
    }()

    private var clips: [Clip] = []
    private var videoRect: CGRect = .zero
    private var layersByID: [String: TextClipLayer] = [:]
    private var currentFrame = 0

    // Materialize layers slightly early so playback never hitches on typesetting.
    private static let prerollFrames = 30

    func sync(timeline: Timeline, videoRect: CGRect) {
        textRoot.frame = videoRect
        self.videoRect = videoRect
        clips = TextLayerController.visibleTextClips(in: timeline)
        reconcile(restyle: true)
    }

    func tick(_ frame: Int) {
        currentFrame = frame
        reconcile(restyle: false)
    }

    // Only clips within the preroll window own a CATextLayer; everything else stays unmaterialized.
    private func reconcile(restyle: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var needed = Set<String>()
        for (index, clip) in clips.enumerated() {
            guard currentFrame >= clip.startFrame - Self.prerollFrames,
                  currentFrame < clip.endFrame else { continue }
            needed.insert(clip.id)

            let layer: TextClipLayer
            if let existing = layersByID[clip.id] {
                layer = existing
                if restyle { layer.apply(clip: clip, containerSize: videoRect.size) }
            } else {
                layer = Self.makeTextLayer()
                layer.apply(clip: clip, containerSize: videoRect.size)
                layersByID[clip.id] = layer
                textRoot.addSublayer(layer)
            }
            layer.zPosition = CGFloat(index)

            let visible = currentFrame >= clip.startFrame
            let target: Float = visible ? Float(clip.opacityAt(frame: currentFrame)) : 0
            if layer.opacity != target { layer.opacity = target }
        }

        for (id, layer) in layersByID where !needed.contains(id) {
            layer.removeFromSuperlayer()
            layersByID[id] = nil
        }

        CATransaction.commit()
    }

    // MARK: - Static builders

    static func buildForExport(
        timeline: Timeline,
        fps: Int,
        renderSize: CGSize
    ) -> (parent: CALayer, videoLayer: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true
        parent.backgroundColor = NSColor.clear.cgColor
        parent.beginTime = AVCoreAnimationBeginTimeAtZero

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        let fpsD = Double(max(1, fps))
        let totalSeconds = max(0.001, Double(max(1, timeline.totalFrames)) / fpsD)
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            layer.apply(clip: clip, containerSize: renderSize)
            applyOpacityAnimation(to: layer, clip: clip, fps: fps, totalSeconds: totalSeconds)
            layer.displayContentIfNeeded()
            parent.addSublayer(layer)
        }
        return (parent, videoLayer)
    }

    static func buildSnapshot(
        timeline: Timeline,
        canvasSize: CGSize,
        atFrame frame: Int
    ) -> CALayer {
        let host = CALayer()
        host.frame = CGRect(origin: .zero, size: canvasSize)
        host.isGeometryFlipped = true
        for clip in visibleTextClips(in: timeline) {
            let layer = makeTextLayer()
            layer.apply(clip: clip, containerSize: canvasSize)
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            layer.opacity = visible ? Float(clip.opacityAt(frame: frame)) : 0
            host.addSublayer(layer)
        }
        return host
    }

    // MARK: - Private

    private static func visibleTextClips(in timeline: Timeline) -> [Clip] {
        var result: [Clip] = []
        for track in timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .text && clip.endFrame > clip.startFrame {
                result.append(clip)
            }
        }
        return result
    }

    private static func makeTextLayer() -> TextClipLayer {
        TextClipLayer.make(contentsScale: NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    /// Export-time opacity
    private static func applyOpacityAnimation(
        to layer: CALayer,
        clip: Clip,
        fps: Int,
        totalSeconds: Double
    ) {
        let fpsD = Double(max(1, fps))
        let total = max(0.001, totalSeconds)
        let totalFrames = max(1, Int((total * fpsD).rounded()))

        layer.opacity = 0

        // Discrete keyframes: values[i] holds in [keyTimes[i], keyTimes[i+1]),
        // so values.count == keyTimes.count - 1. https://developer.apple.com/documentation/quartzcore/cakeyframeanimation
        var keyTimes: [NSNumber] = [NSNumber(value: 0)]
        var values: [NSNumber] = []
        for frame in 0..<totalFrames {
            let visible = frame >= clip.startFrame && frame < clip.endFrame
            let v = visible ? clip.opacityAt(frame: frame) : 0
            values.append(NSNumber(value: Float(v)))
            keyTimes.append(NSNumber(value: Double(frame + 1) / Double(totalFrames)))
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.calculationMode = .discrete
        anim.values = values
        anim.keyTimes = keyTimes
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = total
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "opacity")
    }
}
