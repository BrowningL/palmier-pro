import AppKit
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable {
    var fontName: String = "Helvetica-Bold"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
    var shadow: Shadow = Shadow()
    var background: Fill = Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 0.6))
    /// Kept as `border` in project JSON for compatibility; rendered as a glyph stroke.
    var border: Stroke = Stroke()

    enum Alignment: String, Codable, Sendable, CaseIterable {
        case left
        case center
        case right
    }

    struct RGBA: Codable, Sendable, Equatable {
        var r: Double = 1
        var g: Double = 1
        var b: Double = 1
        var a: Double = 1
    }

    struct Shadow: Codable, Sendable, Equatable {
        var enabled: Bool = true
        /// Alpha doubles as opacity; layer.shadowOpacity stays at 1.
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        /// Canvas points; scaled at render time.
        var offsetX: Double = 0
        var offsetY: Double = -2
        var blur: Double = 6
    }

    /// Toggleable solid color — used for the text box background.
    struct Fill: Codable, Sendable, Equatable {
        var enabled: Bool = false
        var color: RGBA = RGBA()
    }

    struct Stroke: Codable, Sendable, Equatable {
        static let defaultWidth: Double = 3
        static let widthRange: ClosedRange<Double> = 0...20

        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        /// Percentage of the rendered font point size, matching Core Text.
        var width: Double = Stroke.defaultWidth

        private enum CodingKeys: String, CodingKey {
            case enabled, color, width
        }

        init(
            enabled: Bool = false,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1),
            width: Double = Stroke.defaultWidth
        ) {
            self.enabled = enabled
            self.color = color
            self.width = width
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                width: (try? c.decode(Double.self, forKey: .width)) ?? Stroke.defaultWidth
            )
        }

        var clampedWidth: Double {
            min(max(width, Stroke.widthRange.lowerBound), Stroke.widthRange.upperBound)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, color, alignment, shadow, background, border
    }
}

extension TextStyle {
    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontName: (try? c.decode(String.self, forKey: .fontName)) ?? "Helvetica-Bold",
            fontSize: (try? c.decode(Double.self, forKey: .fontSize)) ?? 96,
            fontScale: (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.0,
            color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(),
            alignment: (try? c.decode(Alignment.self, forKey: .alignment)) ?? .center,
            shadow: (try? c.decode(Shadow.self, forKey: .shadow)) ?? Shadow(),
            background: (try? c.decode(Fill.self, forKey: .background)) ?? Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 0.6)),
            border: (try? c.decode(Stroke.self, forKey: .border)) ?? Stroke()
        )
    }
}

// MARK: - Rendering helpers

extension TextStyle.RGBA {
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        )
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: Double(ns.redComponent),
            g: Double(ns.greenComponent),
            b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent)
        )
    }

    /// Accepts `#RGB`, `#RRGGBB`, or `#RRGGBBAA`. Leading `#` optional.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        func component(_ start: Int, _ len: Int) -> Double? {
            let slice = String(chars[start..<start + len])
            let byteStr = len == 1 ? slice + slice : slice
            guard let n = UInt8(byteStr, radix: 16) else { return nil }
            return Double(n) / 255.0
        }
        switch chars.count {
        case 3:
            guard let r = component(0, 1), let g = component(1, 1), let b = component(2, 1) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 6:
            guard let r = component(0, 2), let g = component(2, 2), let b = component(4, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 8:
            guard let r = component(0, 2), let g = component(2, 2),
                  let b = component(4, 2), let a = component(6, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: a)
        default:
            return nil
        }
    }
}

extension TextStyle {
    func resolvedFont(size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    var nsColor: NSColor { color.nsColor }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch alignment {
        case .left: p.alignment = .left
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        }
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// `includeColor: false` for bounding measurement (color doesn't affect size).
    func attributes(
        size: CGFloat,
        includeColor: Bool = true,
        includeStroke: Bool = true
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(size: size),
            .paragraphStyle: paragraphStyle,
        ]
        if includeColor { attrs[.foregroundColor] = nsColor }
        if includeStroke, border.enabled, border.clampedWidth > 0 {
            attrs[.strokeColor] = border.color.nsColor
            attrs[.strokeWidth] = NSNumber(value: -border.clampedWidth)
        }
        return attrs
    }

    func strokeInset(fontSize: CGFloat) -> CGFloat {
        guard border.enabled, border.clampedWidth > 0 else { return 0 }
        return ceil(fontSize * CGFloat(border.clampedWidth / 100))
    }
}

extension TextStyle.Alignment {
    var caTextAlignmentMode: CATextLayerAlignmentMode {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
