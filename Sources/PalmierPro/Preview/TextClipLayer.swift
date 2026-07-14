import AppKit
import CoreText
import QuartzCore

/// Draws an attributed string via CTFramesetter into a bitmap assigned to
/// `contents`. Used instead of CATextLayer when the style needs paragraph
/// features CATextLayer ignores (lineHeightMultiple) or when the pill must
/// stay in exact register with the glyphs — both come from the same layout.
/// A pre-rendered bitmap keeps orientation identical across the live preview,
/// render(in:), and AVFoundation export paths.
final class TextGlyphLayer: CALayer {
    private(set) var renderedImage: CGImage?
    private var attributed: NSAttributedString?
    private var drawingInset: CGFloat = 0
    private var renderedString: NSAttributedString?
    private var renderedSize: CGSize = .zero
    private var renderedScale: CGFloat = 0
    private var renderedInset: CGFloat = -1

    func setAttributed(_ string: NSAttributedString?, drawingInset: CGFloat = 0) {
        attributed = string
        self.drawingInset = max(0, drawingInset)
        renderContents()
    }

    func renderContents() {
        guard let attributed, attributed.length > 0,
              bounds.width >= 1, bounds.height >= 1 else {
            contents = nil
            renderedImage = nil
            renderedString = nil
            return
        }
        let scale = max(0.1, contentsScale)
        // NSAttributedString equality covers attributes; hashValue does not.
        if let renderedString,
           renderedString.isEqual(to: attributed),
           renderedSize == bounds.size,
           renderedScale == scale,
           renderedInset == drawingInset {
            return
        }

        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxInset = max(0, (min(bounds.width, bounds.height) - 1) / 2)
        let inset = min(drawingInset, maxInset)
        let path = CGPath(rect: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, ctx)
        renderedImage = ctx.makeImage()
        contents = renderedImage
        renderedString = attributed.copy() as? NSAttributedString
        renderedSize = bounds.size
        renderedScale = scale
        renderedInset = drawingInset
    }
}

/// One text clip in the layer tree: an Instagram-style pill background under
/// the glyphs. Shared by preview, export, snapshot, and the compositor
/// rasterizer so all four paths style text identically.
final class TextClipLayer: CALayer {
    let pill = CAShapeLayer()
    let text = CATextLayer()
    let glyphs = TextGlyphLayer()

    private static let referenceCanvasHeight: CGFloat = 1080
    private static var suppressedActions: [String: CAAction] { [
        "contents": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "opacity": NSNull(),
        "transform": NSNull(),
        "string": NSNull(),
        "path": NSNull(),
        "fillColor": NSNull(),
        "sublayers": NSNull(),
        "hidden": NSNull(),
    ] }

    static func make(contentsScale: CGFloat) -> TextClipLayer {
        let layer = TextClipLayer()
        layer.masksToBounds = false
        layer.actions = suppressedActions

        layer.pill.contentsScale = contentsScale
        layer.pill.actions = suppressedActions

        layer.text.contentsScale = contentsScale
        layer.text.isWrapped = true
        layer.text.truncationMode = .none
        layer.text.allowsFontSubpixelQuantization = true
        layer.text.actions = suppressedActions

        layer.glyphs.contentsScale = contentsScale
        layer.glyphs.contentsGravity = .resize
        layer.glyphs.actions = suppressedActions

        layer.addSublayer(layer.pill)
        layer.addSublayer(layer.text)
        layer.addSublayer(layer.glyphs)
        return layer
    }

    /// One-shot consumers (rasterizer, export, snapshot) must materialize
    /// drawn content before the tree is rendered or handed to AVFoundation.
    /// (glyphs pre-renders eagerly in apply.)
    func displayContentIfNeeded() {
        text.displayIfNeeded()
    }

    func apply(clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let content = clip.textContent ?? ""
        let scale = containerSize.height / Self.referenceCanvasHeight

        let tl = clip.transform.topLeft
        frame = CGRect(
            x: tl.x * containerSize.width,
            y: tl.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )

        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        let background = style.background
        let strokeInset = style.strokeInset(fontSize: fontSize)
        let hInset = (background.enabled ? max(0, fontSize * CGFloat(background.paddingH)) : 0) + strokeInset
        let vInset = (background.enabled ? max(0, fontSize * CGFloat(background.paddingV)) : 0) + strokeInset
        var textFrame = bounds.insetBy(dx: hInset, dy: vInset)
        if textFrame.width < 1 || textFrame.height < 1 {
            textFrame = bounds
        }
        text.frame = textFrame

        let attributed = NSAttributedString(
            string: content,
            attributes: style.attributes(size: fontSize)
        )
        if style.needsCoreTextRendering {
            glyphs.frame = textFrame.insetBy(dx: -strokeInset, dy: -strokeInset)
            glyphs.setAttributed(attributed, drawingInset: strokeInset)
            glyphs.isHidden = false
            text.string = nil
            text.isHidden = true
        } else {
            text.string = attributed
            text.alignmentMode = style.alignment.caTextAlignmentMode
            text.isHidden = false
            glyphs.setAttributed(nil)
            glyphs.isHidden = true
        }

        if background.enabled {
            pill.frame = bounds
            pill.path = TextBackgroundPath.path(
                for: attributed,
                textArea: textFrame,
                fontSize: fontSize,
                lineHeightMultiple: CGFloat(style.lineHeightMultiple),
                background: background
            )
            pill.fillColor = background.color.nsColor.cgColor
            pill.isHidden = pill.path == nil
        } else {
            pill.path = nil
            pill.isHidden = true
        }

        // `border` is the legacy persistence key; the visible result is now a
        // glyph stroke in the attributed string, never a clip-box rectangle.
        borderColor = nil
        borderWidth = 0

        if style.shadow.enabled {
            shadowColor = style.shadow.color.nsColor.cgColor
            shadowOpacity = 1
            shadowOffset = CGSize(
                width: style.shadow.offsetX * scale,
                height: style.shadow.offsetY * scale
            )
            shadowRadius = max(0, CGFloat(style.shadow.blur) * scale)
        } else {
            shadowOpacity = 0
            shadowRadius = 0
        }
    }
}
