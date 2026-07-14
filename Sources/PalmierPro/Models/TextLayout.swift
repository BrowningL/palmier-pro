import AppKit

/// Natural bounding size of a rendered text clip, shared between the layer
/// controller and clip placement.
enum TextLayout {
    static let shadowPadding: CGFloat = 12
    static let referenceCanvasHeight: CGFloat = 1080

    static func naturalSize(
        content: String,
        style: TextStyle,
        maxWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> CGSize {
        let measured = content.isEmpty ? " " : content
        let canvasScale = canvasHeight / referenceCanvasHeight
        let renderSize = CGFloat(style.fontSize * style.fontScale) * canvasScale
        let pill = style.background.enabled && style.background.shape == .pill
        let bgPadW = pill ? renderSize * CGFloat(style.background.clampedPaddingH) * 2 : 0
        let bgPadH = pill ? renderSize * CGFloat(style.background.clampedPaddingV) * 2 : 0
        let strokeInset = style.strokeInset(fontSize: renderSize)
        let str = NSAttributedString(
            string: measured,
            attributes: style.attributes(size: renderSize, includeColor: false, includeStroke: false)
        )
        let bounding = str.boundingRect(
            with: CGSize(
                width: max(1, maxWidth - bgPadW - strokeInset * 2),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // +4px slack absorbs canvas→preview scale rounding.
        let slack: CGFloat = 4
        let shadowPad = style.shadow.enabled ? shadowPadding * 2 : 0
        return CGSize(
            width: max(1, ceil(bounding.width) + bgPadW + strokeInset * 2 + shadowPad + slack),
            height: max(1, ceil(bounding.height) + bgPadH + strokeInset * 2 + slack)
        )
    }
}
