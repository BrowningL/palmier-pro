import AppKit
import CoreText
import QuartzCore

final class TextGlyphLayer: CALayer {
    private(set) var renderedImage: CGImage?
    private var attributed: NSAttributedString?
    private var inset: CGFloat = 0
    private var renderedString: NSAttributedString?
    private var renderedSize: CGSize = .zero
    private var renderedScale: CGFloat = 0
    private var renderedInset: CGFloat = -1

    func setAttributed(_ string: NSAttributedString?, inset: CGFloat) {
        attributed = string
        self.inset = max(0, inset)
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
        if let renderedString,
           renderedString.isEqual(to: attributed),
           renderedSize == bounds.size,
           renderedScale == scale,
           renderedInset == inset {
            return
        }

        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }

        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        let maxInset = max(0, (min(bounds.width, bounds.height) - 1) / 2)
        let drawRect = bounds.insetBy(dx: min(inset, maxInset), dy: min(inset, maxInset))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: drawRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        renderedImage = context.makeImage()
        contents = renderedImage
        renderedString = attributed.copy() as? NSAttributedString
        renderedSize = bounds.size
        renderedScale = scale
        renderedInset = inset
    }
}

/// Text container shared by preview, snapshot, and encoded video export.
final class TextClipLayer: CATextLayer {
    let glyphs = TextGlyphLayer()

    private static var suppressedActions: [String: CAAction] { [
        "contents": NSNull(),
        "bounds": NSNull(),
        "position": NSNull(),
        "opacity": NSNull(),
        "transform": NSNull(),
        "string": NSNull(),
        "hidden": NSNull(),
    ] }

    static func make(contentsScale: CGFloat) -> TextClipLayer {
        let layer = TextClipLayer()
        layer.contentsScale = contentsScale
        layer.isWrapped = true
        layer.truncationMode = .none
        layer.allowsFontSubpixelQuantization = true
        layer.masksToBounds = false
        layer.actions = suppressedActions

        layer.glyphs.contentsScale = contentsScale
        layer.glyphs.contentsGravity = .resize
        layer.glyphs.actions = suppressedActions
        layer.addSublayer(layer.glyphs)
        return layer
    }

    func apply(clip: Clip, containerSize: CGSize) {
        let style = clip.textStyle ?? TextStyle()
        let scale = containerSize.height / TextLayout.referenceCanvasHeight
        let topLeft = clip.transform.topLeft
        frame = CGRect(
            x: topLeft.x * containerSize.width,
            y: topLeft.y * containerSize.height,
            width: clip.transform.width * containerSize.width,
            height: clip.transform.height * containerSize.height
        )

        let fontSize = CGFloat(style.fontSize * style.fontScale) * scale
        let attributed = NSAttributedString(
            string: clip.textContent ?? "",
            attributes: style.attributes(size: fontSize)
        )
        let strokeInset = style.strokeInset(fontSize: fontSize)
        alignmentMode = style.alignment.caTextAlignmentMode
        glyphs.frame = bounds
        if strokeInset > 0 {
            string = nil
            glyphs.setAttributed(attributed, inset: strokeInset)
            glyphs.isHidden = false
        } else {
            string = attributed
            glyphs.setAttributed(nil, inset: 0)
            glyphs.isHidden = true
        }

        backgroundColor = style.background.enabled ? style.background.color.nsColor.cgColor : nil
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

    func displayContentIfNeeded() {
        if glyphs.isHidden {
            displayIfNeeded()
        } else {
            glyphs.renderContents()
        }
    }
}
