import AppKit
import CoreText

/// Instagram-style text background: the smooth union of one rounded rect per
/// typeset line, hugging each line's width, with concave fillets where
/// adjacent lines differ in width. Coordinates are top-left origin, y down —
/// matching a flipped-geometry layer tree.
enum TextBackgroundPath {

    struct LineBox {
        var x0: CGFloat
        var x1: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var width: CGFloat { x1 - x0 }
    }

    /// `textArea` is the rect the attributed string is typeset into (the text
    /// layer's frame within its parent); the returned path is in the parent's
    /// coordinate space. Returns nil when there is nothing to draw behind.
    static func path(
        for attributed: NSAttributedString,
        textArea: CGRect,
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat = 1.0,
        background: TextStyle.Background
    ) -> CGPath? {
        guard attributed.length > 0, textArea.width > 1, textArea.height > 1, fontSize > 0 else { return nil }
        let padH = fontSize * CGFloat(background.paddingH)
        let padV = fontSize * CGFloat(background.paddingV)
        let radius = max(0, fontSize * CGFloat(background.cornerRadius))

        let runs = lineBoxRuns(
            for: attributed,
            size: textArea.size,
            padH: padH,
            padV: padV,
            metricScale: lineHeightMultiple > 0 ? lineHeightMultiple : 1.0
        )
        guard !runs.isEmpty else { return nil }

        let path = CGMutablePath()
        for run in runs {
            addOutline(for: snapNearEqualEdges(run, threshold: radius * 2), radius: radius, to: path)
        }
        var shift = CGAffineTransform(translationX: textArea.minX, y: textArea.minY)
        return path.copy(using: &shift)
    }

    // MARK: - Line measurement

    /// Consecutive non-empty lines form one blob; blank lines split blobs.
    /// `metricScale` mirrors lineHeightMultiple: CoreText scales the fragment
    /// slots, so the boxes must use the scaled ascent/descent to stay flush.
    private static func lineBoxRuns(
        for attributed: NSAttributedString,
        size: CGSize,
        padH: CGFloat,
        padV: CGFloat,
        metricScale: CGFloat
    ) -> [[LineBox]] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let framePath = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), framePath, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var runs: [[LineBox]] = []
        var current: [LineBox] = []
        for (i, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let full = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let trailing = CTLineGetTrailingWhitespaceWidth(line)
            let lineWidth = CGFloat(full - trailing)
            let baseline = size.height - origins[i].y

            guard lineWidth > 0.5 else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            let box = LineBox(
                x0: origins[i].x - padH,
                x1: origins[i].x + lineWidth + padH,
                top: baseline - ascent * metricScale - padV,
                bottom: baseline + descent * metricScale + padV
            )
            // A vertical gap (possible with negative padding) also splits the blob.
            if let last = current.last, box.top > last.bottom {
                runs.append(current)
                current = []
            }
            current.append(box)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Instagram flushes adjacent lines whose widths nearly match instead of
    /// drawing a sliver of an S-curve.
    private static func snapNearEqualEdges(_ boxes: [LineBox], threshold: CGFloat) -> [LineBox] {
        guard boxes.count > 1, threshold > 0 else { return boxes }
        var result = boxes
        for _ in 0..<result.count {
            var changed = false
            for i in 0..<(result.count - 1) {
                let d0 = abs(result[i].x0 - result[i + 1].x0)
                if d0 > 0.01, d0 <= threshold {
                    let x = min(result[i].x0, result[i + 1].x0)
                    result[i].x0 = x
                    result[i + 1].x0 = x
                    changed = true
                }
                let d1 = abs(result[i].x1 - result[i + 1].x1)
                if d1 > 0.01, d1 <= threshold {
                    let x = max(result[i].x1, result[i + 1].x1)
                    result[i].x1 = x
                    result[i + 1].x1 = x
                    changed = true
                }
            }
            if !changed { break }
        }
        return result
    }

    // MARK: - Outline

    /// Adjacent boxes overlap vertically (each is padded past its line slot);
    /// within the overlap the wider box wins, so each side's step between two
    /// lines happens at the covering box's own edge.
    private static func addOutline(for boxes: [LineBox], radius: CGFloat, to path: CGMutablePath) {
        guard let first = boxes.first, let last = boxes.last else { return }
        let n = boxes.count

        // Per-side boundary y between line i and i+1.
        var rightY: [CGFloat] = []
        var leftY: [CGFloat] = []
        for i in 0..<(n - 1) {
            let a = boxes[i]
            let b = boxes[i + 1]
            rightY.append(a.x1 >= b.x1 ? a.bottom : b.top)
            leftY.append(a.x0 <= b.x0 ? a.bottom : b.top)
        }
        func segHeight(_ boundaries: [CGFloat], _ i: Int) -> CGFloat {
            let top = i == 0 ? boxes[0].top : boundaries[i - 1]
            let bottom = i == n - 1 ? boxes[n - 1].bottom : boundaries[i]
            return max(0, bottom - top)
        }

        func corner(_ i: Int, side boundaries: [CGFloat]) -> CGFloat {
            min(radius, boxes[i].width / 2, segHeight(boundaries, i) / 2)
        }

        let rTL = corner(0, side: leftY)
        let rTR = corner(0, side: rightY)
        let rBR = corner(n - 1, side: rightY)
        let rBL = corner(n - 1, side: leftY)

        path.move(to: CGPoint(x: first.x0 + rTL, y: first.top))
        path.addLine(to: CGPoint(x: first.x1 - rTR, y: first.top))
        path.addArc(
            tangent1End: CGPoint(x: first.x1, y: first.top),
            tangent2End: CGPoint(x: first.x1, y: first.top + rTR),
            radius: rTR
        )

        // Right side, top to bottom.
        for i in 0..<(n - 1) {
            let a = boxes[i]
            let b = boxes[i + 1]
            let dx = b.x1 - a.x1
            guard abs(dx) > 0.5 else { continue }
            let rc = min(radius, abs(dx) / 2, segHeight(rightY, i) / 2, segHeight(rightY, i + 1) / 2)
            let y = rightY[i]
            if dx < 0 {
                path.addArc(
                    tangent1End: CGPoint(x: a.x1, y: y),
                    tangent2End: CGPoint(x: a.x1 - rc, y: y),
                    radius: rc
                )
                path.addArc(
                    tangent1End: CGPoint(x: b.x1, y: y),
                    tangent2End: CGPoint(x: b.x1, y: y + rc),
                    radius: rc
                )
            } else {
                path.addArc(
                    tangent1End: CGPoint(x: a.x1, y: y),
                    tangent2End: CGPoint(x: a.x1 + rc, y: y),
                    radius: rc
                )
                path.addArc(
                    tangent1End: CGPoint(x: b.x1, y: y),
                    tangent2End: CGPoint(x: b.x1, y: y + rc),
                    radius: rc
                )
            }
        }

        path.addArc(
            tangent1End: CGPoint(x: last.x1, y: last.bottom),
            tangent2End: CGPoint(x: last.x1 - rBR, y: last.bottom),
            radius: rBR
        )
        path.addArc(
            tangent1End: CGPoint(x: last.x0, y: last.bottom),
            tangent2End: CGPoint(x: last.x0, y: last.bottom - rBL),
            radius: rBL
        )

        // Left side, bottom to top.
        for i in (0..<(n - 1)).reversed() {
            let a = boxes[i]
            let b = boxes[i + 1]
            let dx = b.x0 - a.x0
            guard abs(dx) > 0.5 else { continue }
            let rc = min(radius, abs(dx) / 2, segHeight(leftY, i) / 2, segHeight(leftY, i + 1) / 2)
            let y = leftY[i]
            if dx < 0 {
                path.addArc(
                    tangent1End: CGPoint(x: b.x0, y: y),
                    tangent2End: CGPoint(x: b.x0 + rc, y: y),
                    radius: rc
                )
                path.addArc(
                    tangent1End: CGPoint(x: a.x0, y: y),
                    tangent2End: CGPoint(x: a.x0, y: y - rc),
                    radius: rc
                )
            } else {
                path.addArc(
                    tangent1End: CGPoint(x: b.x0, y: y),
                    tangent2End: CGPoint(x: b.x0 - rc, y: y),
                    radius: rc
                )
                path.addArc(
                    tangent1End: CGPoint(x: a.x0, y: y),
                    tangent2End: CGPoint(x: a.x0, y: y - rc),
                    radius: rc
                )
            }
        }

        path.addArc(
            tangent1End: CGPoint(x: first.x0, y: first.top),
            tangent2End: CGPoint(x: first.x0 + rTL, y: first.top),
            radius: rTL
        )
        path.closeSubpath()
    }
}
