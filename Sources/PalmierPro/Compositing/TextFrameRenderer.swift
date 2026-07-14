import AppKit
import CoreImage
import CoreText

/// Renders a text clip as a CIImage using CoreText on the compositor queue
enum TextFrameRenderer {
    // NSCache is internally thread-safe; the compositor queue and main thread both hit it.
    nonisolated(unsafe) private static let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.totalCostLimit = 256 * 1_024 * 1_024
        cache.countLimit = 256
        return cache
    }()

    static func clearCache() {
        cache.removeAllObjects()
    }

    static func image(clip: Clip, frame: Int, renderSize: CGSize) -> CIImage? {
        guard renderSize.width >= 1, renderSize.height >= 1 else { return nil }
        let content = clip.textContent ?? ""
        guard !content.isEmpty else { return nil }
        let style = clip.textStyle ?? TextStyle()
        let box = boxRect(clip.transform, renderSize)
        let fontSize = CGFloat(style.fontSize * style.fontScale) * (renderSize.height / TextLayout.referenceCanvasHeight)
        let textRect = textRect(style: style, box: box, fontSize: fontSize)
        let anim = clip.textAnimation

        if let anim, anim.isActive {
            switch anim.preset.renderMode {
            case .perWord:
                return renderPerWord(clip: clip, content: content, style: style, box: box, textRect: textRect,
                                     fontSize: fontSize, anim: anim, frame: frame, renderSize: renderSize)
            case .typewriter:
                return renderTypewriter(clip: clip, content: content, style: style, box: box, textRect: textRect,
                                        fontSize: fontSize, frame: frame, renderSize: renderSize)
            case .entrance:
                break
            }
        }

        // Static base is frame-independent → cache it. Entrance reuses it under a transform.
        guard let base = cachedStatic(content: content, style: style, transform: clip.transform,
                                      box: box, textRect: textRect, fontSize: fontSize,
                                      renderSize: renderSize) else { return nil }
        guard let anim, anim.isActive else { return base }
        return applyEntrance(base, TextAnimator.clipEntry(anim, rel: frame - clip.startFrame),
                             box: box, renderSize: renderSize)
    }

    // MARK: - Geometry

    /// Clip box in CG y-up coords (origin bottom-left); transform.topLeft is top-down.
    private static func boxRect(_ t: Transform, _ size: CGSize) -> CGRect {
        let tl = t.topLeft
        let h = max(1, t.height * size.height)
        return CGRect(x: tl.x * size.width, y: size.height - tl.y * size.height - h,
                      width: max(1, t.width * size.width), height: h)
    }

    private static func textRect(style: TextStyle, box: CGRect, fontSize: CGFloat) -> CGRect {
        let pill = style.background.enabled && style.background.shape == .pill
        let stroke = style.strokeInset(fontSize: fontSize)
        let horizontal = (pill ? fontSize * CGFloat(style.background.clampedPaddingH) : 0) + stroke
        let vertical = (pill ? fontSize * CGFloat(style.background.clampedPaddingV) : 0) + stroke
        let inset = box.insetBy(dx: horizontal, dy: vertical)
        return inset.width >= 1 && inset.height >= 1 ? inset : box
    }

    private static func beginContext(renderSize: CGSize) -> CGContext? {
        guard let ctx = CGContext(
            data: nil, width: Int(renderSize.width.rounded()), height: Int(renderSize.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        return ctx
    }

    /// Premultiplied, NO color space — FrameRenderer unpremultiplies it like a source buffer.
    private static func finish(_ ctx: CGContext) -> CIImage? {
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    private static func layoutFrame(_ attr: NSAttributedString, box: CGRect, finiteHeight: Bool) -> CTFrame {
        let setter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let rect = finiteHeight
            ? box
            : CGRect(x: box.minX, y: 0, width: box.width, height: box.maxY)
        let path = CGPath(rect: rect, transform: nil)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }

    // MARK: - Static

    private static func cachedStatic(content: String, style: TextStyle, transform: Transform,
                                     box: CGRect, textRect: CGRect, fontSize: CGFloat,
                                     renderSize: CGSize) -> CIImage? {
        let key = signature(content, style, transform, renderSize)
        if let cached = cache.object(forKey: key) { return cached }
        guard let ctx = beginContext(renderSize: renderSize) else { return nil }
        let attributed = NSAttributedString(string: content, attributes: style.attributes(size: fontSize))
        drawBackground(
            ctx, attributed: attributed, style: style, box: box, textRect: textRect,
            fontSize: fontSize, renderSize: renderSize
        )
        applyShadow(ctx, style: style, renderSize: renderSize)
        CTFrameDraw(
            layoutFrame(
                attributed,
                box: textRect,
                finiteHeight: style.background.enabled && style.background.shape == .pill
            ),
            ctx
        )
        guard let image = finish(ctx) else { return nil }
        let cost = max(1, Int(renderSize.width.rounded()) * Int(renderSize.height.rounded()) * 4)
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }

    // MARK: - Entrance (whole-clip)

    private static func applyEntrance(_ base: CIImage, _ st: TextAnimator.ClipState,
                                      box: CGRect, renderSize: CGSize) -> CIImage {
        var img = base
        if st.scale != 1 || st.dy != 0 {
            let cx = box.midX, cy = box.midY
            var t = CGAffineTransform(translationX: cx, y: cy)
                .scaledBy(x: st.scale, y: st.scale)
                .translatedBy(x: -cx, y: -cy)
            t = t.translatedBy(x: 0, y: -st.dy * renderSize.height)  // dy positive = down = -y in CI
            img = img.transformed(by: t)
        }
        if st.opacity < 1 {
            let k = CGFloat(st.opacity)  // premultiplied coverage scale → all four channels
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
            ])
        }
        return img
    }

    // MARK: - Per-word

    private static func renderPerWord(clip: Clip, content: String, style: TextStyle, box: CGRect,
                                      textRect: CGRect,
                                      fontSize: CGFloat, anim: TextAnimation, frame: Int, renderSize: CGSize) -> CIImage? {
        guard let ctx = beginContext(renderSize: renderSize) else { return nil }
        let attr = NSAttributedString(string: content, attributes: style.attributes(size: fontSize))
        drawBackground(
            ctx, attributed: attr, style: style, box: box, textRect: textRect,
            fontSize: fontSize, renderSize: renderSize
        )
        applyShadow(ctx, style: style, renderSize: renderSize)
        let ctFrame = layoutFrame(
            attr,
            box: textRect,
            finiteHeight: style.background.enabled && style.background.shape == .pill
        )
        let lines = CTFrameGetLines(ctFrame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        let rel = frame - clip.startFrame
        let baseAttrs = style.attributes(size: fontSize)
        let font = baseAttrs[.font] as? NSFont

        for (li, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            for (ti, tok) in tokens.enumerated() {
                guard tok.range.location >= lineRange.location,
                      tok.range.location < lineRange.location + lineRange.length else { continue }
                let st = TextAnimator.wordState(anim, word: timings[ti], rel: rel, base: style.color)
                guard st.opacity > 0 else { continue }

                let startOff = CTLineGetOffsetForStringIndex(line, tok.range.location, nil)
                let endOff = CTLineGetOffsetForStringIndex(line, tok.range.location + tok.range.length, nil)
                let penX = textRect.minX + origins[li].x + startOff
                let penY = origins[li].y
                let wWidth = endOff - startOff

                var attrs = baseAttrs
                attrs[.foregroundColor] = st.color.nsColor
                let wordLine = CTLineCreateWithAttributedString(
                    NSAttributedString(string: tok.text, attributes: attrs) as CFAttributedString)

                ctx.saveGState()
                ctx.setAlpha(CGFloat(st.opacity))
                let cx = penX + wWidth / 2, cy = penY + fontSize * 0.35
                ctx.translateBy(x: 0, y: -st.dy * fontSize)
                ctx.translateBy(x: cx, y: cy)
                ctx.scaleBy(x: st.scale, y: st.scale)
                ctx.translateBy(x: -cx, y: -cy)
                if let bg = st.bgColor, bg.a > 0.001 {
                    drawWordBackground(ctx, color: bg, penX: penX, penY: penY,
                                       width: wWidth, fontSize: fontSize, font: font)
                }
                ctx.textPosition = CGPoint(x: penX, y: penY)
                CTLineDraw(wordLine, ctx)
                ctx.restoreGState()
            }
        }
        return finish(ctx)
    }

    /// Rounded highlight block behind a word.
    private static func drawWordBackground(_ ctx: CGContext, color: TextStyle.RGBA,
                                           penX: CGFloat, penY: CGFloat, width: CGFloat,
                                           fontSize: CGFloat, font: NSFont?) {
        let ascent = font?.ascender ?? fontSize * 0.8
        let descent = abs(font?.descender ?? fontSize * 0.2)
        let padX = fontSize * 0.18, padY = fontSize * 0.10
        let rect = CGRect(x: penX - padX, y: penY - descent - padY,
                          width: width + padX * 2, height: ascent + descent + padY * 2)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.12,
                           cornerHeight: fontSize * 0.12, transform: nil))
        ctx.setFillColor(cgColor(color))
        ctx.fillPath()
    }

    // MARK: - Typewriter (whole-clip character reveal)

    private static func renderTypewriter(clip: Clip, content: String, style: TextStyle, box: CGRect,
                                         textRect: CGRect,
                                         fontSize: CGFloat, frame: Int, renderSize: CGSize) -> CIImage? {
        guard let ctx = beginContext(renderSize: renderSize) else { return nil }
        let rel = frame - clip.startFrame
        let ns = content as NSString

        let tokens = words(in: content)
        let timings = tokenTimings(tokens, clip.wordTimings, duration: clip.durationFrames)
        var visLen = 0
        for (i, tok) in tokens.enumerated() {
            let t = timings[i]
            if rel >= t.endFrame {
                visLen = tok.range.location + tok.range.length
            } else if rel >= t.startFrame {
                let p = Double(rel - t.startFrame) / Double(max(1, t.endFrame - t.startFrame))
                visLen = tok.range.location + Int((Double(tok.range.length) * p).rounded(.down))
                break
            } else {
                break
            }
        }
        var visible = ns.substring(to: min(visLen, ns.length))
        // Caret blinks (~0.5s) until shortly after the last word finishes.
        let doneAt = timings.last?.endFrame ?? clip.durationFrames
        if rel <= doneAt + 18, (rel / 15) % 2 == 0 { visible += "|" }
        guard !visible.isEmpty else {
            drawBackground(
                ctx, attributed: NSAttributedString(), style: style, box: box, textRect: textRect,
                fontSize: fontSize, renderSize: renderSize
            )
            return finish(ctx)
        }
        // Left-anchor so the text reveals rightward in place rather than re-centering as it grows.
        var attrs = style.attributes(size: fontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = CGFloat(style.clampedLineHeightMultiple)
        attrs[.paragraphStyle] = para
        let attributed = NSAttributedString(string: visible, attributes: attrs)
        drawBackground(
            ctx, attributed: attributed, style: style, box: box, textRect: textRect,
            fontSize: fontSize, renderSize: renderSize
        )
        applyShadow(ctx, style: style, renderSize: renderSize)
        CTFrameDraw(
            layoutFrame(
                attributed,
                box: textRect,
                finiteHeight: style.background.enabled && style.background.shape == .pill
            ),
            ctx
        )
        return finish(ctx)
    }

    /// Returns one timing per token, aligning transcript spans when token counts differ.
    static func tokenTimings(_ tokens: [(range: NSRange, text: String)],
                             _ words: [WordTiming]?, duration: Int) -> [WordTiming] {
        guard !tokens.isEmpty else { return [] }
        guard let words, !words.isEmpty else { return evenTokenTimings(tokens, duration: duration) }
        if words.count == tokens.count {
            return zip(tokens, words).map { pair in
                let (token, timing) = pair
                return clampedTiming(timing, text: token.text, duration: duration)
            }
        }
        return alignedTokenTimings(tokens, words: words, duration: duration)
            ?? evenTokenTimings(tokens, duration: duration)
    }

    private static func evenTokenTimings(_ tokens: [(range: NSRange, text: String)], duration: Int) -> [WordTiming] {
        let duration = max(0, duration)
        let n = max(1, tokens.count)
        return tokens.indices.map {
            WordTiming(text: tokens[$0].text, startFrame: duration * $0 / n, endFrame: duration * ($0 + 1) / n)
        }
    }

    private struct TimingAlignmentGroup {
        let tokenRange: Range<Int>
        let wordRange: Range<Int>
    }

    private static func alignedTokenTimings(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        duration: Int
    ) -> [WordTiming]? {
        var result: [WordTiming] = []
        var tokenIndex = 0
        var wordIndex = 0

        while tokenIndex < tokens.count, wordIndex < words.count {
            guard let group = nextAlignedTimingGroup(
                tokens,
                words: words,
                tokenStart: tokenIndex,
                wordStart: wordIndex
            ) else { return nil }

            result.append(contentsOf: timingsForAlignedGroup(
                tokens,
                words: words,
                tokenRange: group.tokenRange,
                wordRange: group.wordRange,
                duration: duration
            ))
            tokenIndex = group.tokenRange.upperBound
            wordIndex = group.wordRange.upperBound
        }

        guard tokenIndex == tokens.count, wordIndex == words.count, result.count == tokens.count else { return nil }
        return result
    }

    private static func nextAlignedTimingGroup(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        tokenStart: Int,
        wordStart: Int
    ) -> TimingAlignmentGroup? {
        var tokenEnd = tokenStart
        var wordEnd = wordStart
        var tokenText = ""
        var wordText = ""

        while tokenEnd < tokens.count || wordEnd < words.count {
            if shouldAppendTokenText(
                tokenText: tokenText,
                wordText: wordText,
                tokenEnd: tokenEnd,
                wordEnd: wordEnd,
                tokenCount: tokens.count,
                wordCount: words.count
            ) {
                tokenText += normalizedTimingText(tokens[tokenEnd].text)
                tokenEnd += 1
            } else {
                wordText += normalizedTimingText(words[wordEnd].text)
                wordEnd += 1
            }

            if !tokenText.isEmpty, tokenText == wordText {
                return TimingAlignmentGroup(
                    tokenRange: tokenStart..<tokenEnd,
                    wordRange: wordStart..<wordEnd
                )
            }
        }

        return nil
    }

    private static func shouldAppendTokenText(
        tokenText: String,
        wordText: String,
        tokenEnd: Int,
        wordEnd: Int,
        tokenCount: Int,
        wordCount: Int
    ) -> Bool {
        if wordEnd >= wordCount { return true }
        if tokenEnd >= tokenCount { return false }
        return tokenText.count <= wordText.count
    }

    private static func timingsForAlignedGroup(
        _ tokens: [(range: NSRange, text: String)],
        words: [WordTiming],
        tokenRange: Range<Int>,
        wordRange: Range<Int>,
        duration: Int
    ) -> [WordTiming] {
        if tokenRange.count == wordRange.count {
            return zip(tokenRange, wordRange).map { pair in
                let (tokenIndex, wordIndex) = pair
                return clampedTiming(words[wordIndex], text: tokens[tokenIndex].text, duration: duration)
            }
        }

        let maxFrame = max(0, duration)
        let start = min(max(0, words[wordRange.lowerBound].startFrame), maxFrame)
        let end = min(max(start, words[wordRange.upperBound - 1].endFrame), maxFrame)
        let span = max(0, end - start)
        return tokenRange.enumerated().map { offset, tokenIndex in
            let tokenStart = start + span * offset / tokenRange.count
            let tokenEnd: Int
            if offset == tokenRange.count - 1 {
                tokenEnd = end
            } else {
                tokenEnd = start + span * (offset + 1) / tokenRange.count
            }
            return WordTiming(text: tokens[tokenIndex].text, startFrame: tokenStart, endFrame: tokenEnd)
        }
    }

    private static func clampedTiming(_ timing: WordTiming, text: String, duration: Int) -> WordTiming {
        let maxFrame = max(0, duration)
        let start = min(max(0, timing.startFrame), maxFrame)
        let end = min(max(start, timing.endFrame), maxFrame)
        return WordTiming(text: text, startFrame: start, endFrame: end)
    }

    private static func normalizedTimingText(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            out += String(scalar).lowercased()
        }
        return out
    }

    private static func words(in content: String) -> [(range: NSRange, text: String)] {
        let ns = content as NSString
        let ws = CharacterSet.whitespacesAndNewlines
        // A surrogate half (emoji etc.) maps to no scalar — treat it as part of a word, not whitespace.
        func isSpace(_ u: unichar) -> Bool { Unicode.Scalar(u).map(ws.contains) ?? false }
        var result: [(NSRange, String)] = []
        var i = 0
        while i < ns.length {
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
            guard i < ns.length else { break }
            let start = i
            while i < ns.length, !isSpace(ns.character(at: i)) { i += 1 }
            let r = NSRange(location: start, length: i - start)
            result.append((r, ns.substring(with: r)))
        }
        return result
    }

    // MARK: - Shared drawing

    private static func drawBackground(
        _ ctx: CGContext,
        attributed: NSAttributedString,
        style: TextStyle,
        box: CGRect,
        textRect: CGRect,
        fontSize: CGFloat,
        renderSize: CGSize
    ) {
        guard style.background.enabled else { return }
        ctx.setFillColor(cgColor(style.background.color))
        guard style.background.shape == .pill else {
            ctx.fill(box)
            return
        }
        let topDownTextArea = CGRect(
            x: textRect.minX,
            y: renderSize.height - textRect.maxY,
            width: textRect.width,
            height: textRect.height
        )
        guard let path = TextBackgroundPath.path(
            for: attributed,
            textArea: topDownTextArea,
            fontSize: fontSize,
            lineHeightMultiple: CGFloat(style.clampedLineHeightMultiple),
            background: style.background
        ) else { return }
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
        guard let flipped = path.copy(using: &flip) else { return }
        ctx.addPath(flipped)
        ctx.fillPath()
    }

    private static func applyShadow(_ ctx: CGContext, style: TextStyle, renderSize: CGSize) {
        guard style.shadow.enabled else { return }
        let scale = renderSize.height / TextLayout.referenceCanvasHeight
        ctx.setShadow(
            offset: CGSize(width: style.shadow.offsetX * scale, height: -style.shadow.offsetY * scale),
            blur: max(0, CGFloat(style.shadow.blur) * scale),
            color: cgColor(style.shadow.color)
        )
    }

    static func cgColor(_ c: TextStyle.RGBA) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    private static func signature(_ content: String, _ s: TextStyle, _ t: Transform, _ size: CGSize) -> NSString {
        var h = Hasher()
        h.combine(content); h.combine(s); h.combine(t); h.combine(size)
        return String(h.finalize()) as NSString
    }
}
