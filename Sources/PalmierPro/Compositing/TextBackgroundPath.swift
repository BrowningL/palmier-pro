import AppKit
import CoreText

enum TextBackgroundPath {
    struct LineBox {
        var x0: CGFloat
        var x1: CGFloat
        var top: CGFloat
        var bottom: CGFloat
        var width: CGFloat { x1 - x0 }
    }

    static func path(
        for attributed: NSAttributedString,
        textArea: CGRect,
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat = 1,
        background: TextStyle.Background
    ) -> CGPath? {
        guard attributed.length > 0, textArea.width > 1, textArea.height > 1, fontSize > 0 else { return nil }
        let padH = fontSize * CGFloat(background.clampedPaddingH)
        let padV = fontSize * CGFloat(background.clampedPaddingV)
        let radius = fontSize * CGFloat(background.clampedCornerRadius)
        let runs = lineBoxRuns(
            for: attributed,
            size: textArea.size,
            padH: padH,
            padV: padV,
            metricScale: lineHeightMultiple > 0 ? lineHeightMultiple : 1
        )
        guard !runs.isEmpty else { return nil }

        let path = CGMutablePath()
        for run in runs {
            addOutline(for: snapNearEqualEdges(run, threshold: radius * 2), radius: radius, to: path)
        }
        var shift = CGAffineTransform(translationX: textArea.minX, y: textArea.minY)
        return path.copy(using: &shift)
    }

    private static func lineBoxRuns(
        for attributed: NSAttributedString,
        size: CGSize,
        padH: CGFloat,
        padV: CGFloat,
        metricScale: CGFloat
    ) -> [[LineBox]] {
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let framePath = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: attributed.length), framePath, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var runs: [[LineBox]] = []
        var current: [LineBox] = []
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let full = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let lineWidth = CGFloat(full - CTLineGetTrailingWhitespaceWidth(line))
            let baseline = size.height - origins[index].y

            guard lineWidth > 0.5 else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            let box = LineBox(
                x0: origins[index].x - padH,
                x1: origins[index].x + lineWidth + padH,
                top: baseline - ascent * metricScale - padV,
                bottom: baseline + descent * metricScale + padV
            )
            if let last = current.last, box.top > last.bottom {
                runs.append(current)
                current = []
            }
            current.append(box)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func snapNearEqualEdges(_ boxes: [LineBox], threshold: CGFloat) -> [LineBox] {
        guard boxes.count > 1, threshold > 0 else { return boxes }
        var result = boxes
        for _ in result.indices {
            var changed = false
            for index in 0..<(result.count - 1) {
                let leftDelta = abs(result[index].x0 - result[index + 1].x0)
                if leftDelta > 0.01, leftDelta <= threshold {
                    let x = min(result[index].x0, result[index + 1].x0)
                    result[index].x0 = x
                    result[index + 1].x0 = x
                    changed = true
                }
                let rightDelta = abs(result[index].x1 - result[index + 1].x1)
                if rightDelta > 0.01, rightDelta <= threshold {
                    let x = max(result[index].x1, result[index + 1].x1)
                    result[index].x1 = x
                    result[index + 1].x1 = x
                    changed = true
                }
            }
            if !changed { break }
        }
        return result
    }

    private static func addOutline(for boxes: [LineBox], radius: CGFloat, to path: CGMutablePath) {
        guard let first = boxes.first, let last = boxes.last else { return }
        let count = boxes.count
        var rightY: [CGFloat] = []
        var leftY: [CGFloat] = []
        for index in 0..<(count - 1) {
            let a = boxes[index]
            let b = boxes[index + 1]
            rightY.append(a.x1 >= b.x1 ? a.bottom : b.top)
            leftY.append(a.x0 <= b.x0 ? a.bottom : b.top)
        }
        func segmentHeight(_ boundaries: [CGFloat], _ index: Int) -> CGFloat {
            let top = index == 0 ? boxes[0].top : boundaries[index - 1]
            let bottom = index == count - 1 ? boxes[count - 1].bottom : boundaries[index]
            return max(0, bottom - top)
        }
        func corner(_ index: Int, boundaries: [CGFloat]) -> CGFloat {
            min(radius, boxes[index].width / 2, segmentHeight(boundaries, index) / 2)
        }

        let topLeft = corner(0, boundaries: leftY)
        let topRight = corner(0, boundaries: rightY)
        let bottomRight = corner(count - 1, boundaries: rightY)
        let bottomLeft = corner(count - 1, boundaries: leftY)

        path.move(to: CGPoint(x: first.x0 + topLeft, y: first.top))
        path.addLine(to: CGPoint(x: first.x1 - topRight, y: first.top))
        path.addArc(
            tangent1End: CGPoint(x: first.x1, y: first.top),
            tangent2End: CGPoint(x: first.x1, y: first.top + topRight),
            radius: topRight
        )

        for index in 0..<(count - 1) {
            let a = boxes[index]
            let b = boxes[index + 1]
            let delta = b.x1 - a.x1
            guard abs(delta) > 0.5 else { continue }
            let fillet = min(
                radius,
                abs(delta) / 2,
                segmentHeight(rightY, index) / 2,
                segmentHeight(rightY, index + 1) / 2
            )
            let y = rightY[index]
            if delta < 0 {
                path.addArc(
                    tangent1End: CGPoint(x: a.x1, y: y),
                    tangent2End: CGPoint(x: a.x1 - fillet, y: y),
                    radius: fillet
                )
                path.addArc(
                    tangent1End: CGPoint(x: b.x1, y: y),
                    tangent2End: CGPoint(x: b.x1, y: y + fillet),
                    radius: fillet
                )
            } else {
                path.addArc(
                    tangent1End: CGPoint(x: a.x1, y: y),
                    tangent2End: CGPoint(x: a.x1 + fillet, y: y),
                    radius: fillet
                )
                path.addArc(
                    tangent1End: CGPoint(x: b.x1, y: y),
                    tangent2End: CGPoint(x: b.x1, y: y + fillet),
                    radius: fillet
                )
            }
        }

        path.addArc(
            tangent1End: CGPoint(x: last.x1, y: last.bottom),
            tangent2End: CGPoint(x: last.x1 - bottomRight, y: last.bottom),
            radius: bottomRight
        )
        path.addArc(
            tangent1End: CGPoint(x: last.x0, y: last.bottom),
            tangent2End: CGPoint(x: last.x0, y: last.bottom - bottomLeft),
            radius: bottomLeft
        )

        for index in (0..<(count - 1)).reversed() {
            let a = boxes[index]
            let b = boxes[index + 1]
            let delta = b.x0 - a.x0
            guard abs(delta) > 0.5 else { continue }
            let fillet = min(
                radius,
                abs(delta) / 2,
                segmentHeight(leftY, index) / 2,
                segmentHeight(leftY, index + 1) / 2
            )
            let y = leftY[index]
            if delta < 0 {
                path.addArc(
                    tangent1End: CGPoint(x: b.x0, y: y),
                    tangent2End: CGPoint(x: b.x0 + fillet, y: y),
                    radius: fillet
                )
                path.addArc(
                    tangent1End: CGPoint(x: a.x0, y: y),
                    tangent2End: CGPoint(x: a.x0, y: y - fillet),
                    radius: fillet
                )
            } else {
                path.addArc(
                    tangent1End: CGPoint(x: b.x0, y: y),
                    tangent2End: CGPoint(x: b.x0 - fillet, y: y),
                    radius: fillet
                )
                path.addArc(
                    tangent1End: CGPoint(x: a.x0, y: y),
                    tangent2End: CGPoint(x: a.x0, y: y - fillet),
                    radius: fillet
                )
            }
        }

        path.addArc(
            tangent1End: CGPoint(x: first.x0, y: first.top),
            tangent2End: CGPoint(x: first.x0 + topLeft, y: first.top),
            radius: topLeft
        )
        path.closeSubpath()
    }
}
