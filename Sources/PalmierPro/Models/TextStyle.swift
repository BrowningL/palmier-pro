import AppKit
import CoreText
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable, Hashable {
    var fontName: String = "Helvetica-Bold"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    var lineHeightMultiple: Double = 1.0
    var isBold: Bool = true
    var isItalic: Bool = false
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
    var shadow: Shadow = Shadow()
    var background: Background = Background()
    var border: Stroke = Stroke()

    enum Alignment: String, Codable, Sendable, CaseIterable, Hashable {
        case left
        case center
        case right
    }

    struct RGBA: Codable, Sendable, Equatable, Hashable {
        var r: Double = 1
        var g: Double = 1
        var b: Double = 1
        var a: Double = 1
    }

    struct Shadow: Codable, Sendable, Equatable, Hashable {
        var enabled: Bool = true
        /// Alpha doubles as opacity; layer.shadowOpacity stays at 1.
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        /// Canvas points; scaled at render time.
        var offsetX: Double = 0
        var offsetY: Double = -2
        var blur: Double = 6
    }

    struct Background: Codable, Sendable, Equatable, Hashable {
        enum Shape: String, Codable, Sendable, CaseIterable, Hashable {
            case box
            case pill
        }

        static let defaultPaddingH: Double = 0.35
        static let defaultPaddingV: Double = 0.435
        static let defaultCornerRadius: Double = 0.22
        static let paddingRange: ClosedRange<Double> = 0...1
        static let cornerRadiusRange: ClosedRange<Double> = 0...0.6

        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        var shape: Shape = .box
        var paddingH: Double = Background.defaultPaddingH
        var paddingV: Double = Background.defaultPaddingV
        var cornerRadius: Double = Background.defaultCornerRadius

        private enum CodingKeys: String, CodingKey {
            case enabled, color, shape, paddingH, paddingV, cornerRadius
        }

        init(
            enabled: Bool = false,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6),
            shape: Shape = .box,
            paddingH: Double = Background.defaultPaddingH,
            paddingV: Double = Background.defaultPaddingV,
            cornerRadius: Double = Background.defaultCornerRadius
        ) {
            self.enabled = enabled
            self.color = color
            self.shape = shape
            self.paddingH = paddingH
            self.paddingV = paddingV
            self.cornerRadius = cornerRadius
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let carriesForkGeometry = c.contains(.paddingH) || c.contains(.paddingV) || c.contains(.cornerRadius)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 0.6),
                shape: (try? c.decode(Shape.self, forKey: .shape)) ?? (carriesForkGeometry ? .pill : .box),
                paddingH: (try? c.decode(Double.self, forKey: .paddingH)) ?? Background.defaultPaddingH,
                paddingV: (try? c.decode(Double.self, forKey: .paddingV)) ?? Background.defaultPaddingV,
                cornerRadius: (try? c.decode(Double.self, forKey: .cornerRadius)) ?? Background.defaultCornerRadius
            )
        }

        var clampedPaddingH: Double { Self.clamp(paddingH, to: Self.paddingRange, fallback: Self.defaultPaddingH) }
        var clampedPaddingV: Double { Self.clamp(paddingV, to: Self.paddingRange, fallback: Self.defaultPaddingV) }
        var clampedCornerRadius: Double {
            Self.clamp(cornerRadius, to: Self.cornerRadiusRange, fallback: Self.defaultCornerRadius)
        }

        private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
    }

    struct Stroke: Codable, Sendable, Equatable, Hashable {
        static let defaultWidth: Double = 3
        static let legacyUpstreamWidth: Double = 4
        static let widthRange: ClosedRange<Double> = 0...20

        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
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
                width: (try? c.decode(Double.self, forKey: .width)) ?? Stroke.legacyUpstreamWidth
            )
        }

        var clampedWidth: Double {
            guard width.isFinite else { return Stroke.defaultWidth }
            return min(max(width, Stroke.widthRange.lowerBound), Stroke.widthRange.upperBound)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, lineHeightMultiple, isBold, isItalic
        case color, alignment, shadow, background, border
    }
}

extension TextStyle {
    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fontName = (try? c.decode(String.self, forKey: .fontName)) ?? "Helvetica-Bold"
        let fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 96
        let inferredTraits: CTFontSymbolicTraits = fontName == Self.systemBoldFontName
            ? [.traitBold]
            : Self.symbolicTraits(fontName: fontName, size: CGFloat(fontSize))
        self.init(
            fontName: fontName,
            fontSize: fontSize,
            fontScale: (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.0,
            lineHeightMultiple: (try? c.decode(Double.self, forKey: .lineHeightMultiple)) ?? 1.0,
            isBold: (try? c.decode(Bool.self, forKey: .isBold)) ?? inferredTraits.contains(.traitBold),
            isItalic: (try? c.decode(Bool.self, forKey: .isItalic)) ?? inferredTraits.contains(.traitItalic),
            color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(),
            alignment: (try? c.decode(Alignment.self, forKey: .alignment)) ?? .center,
            shadow: (try? c.decode(Shadow.self, forKey: .shadow)) ?? Shadow(),
            background: (try? c.decode(Background.self, forKey: .background)) ?? Background(),
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
    enum Preset: String, CaseIterable, Sendable {
        case instagramLight
        case instagramDark
    }

    static let systemBoldFontName = "SF Pro Bold"
    static let instagramLineHeightMultiple = 0.912
    static let lineHeightRange: ClosedRange<Double> = 0.5...2

    mutating func apply(_ preset: Preset) {
        fontName = Self.systemBoldFontName
        isBold = true
        isItalic = false
        lineHeightMultiple = Self.instagramLineHeightMultiple
        background = Background(
            enabled: true,
            color: preset == .instagramLight ? RGBA() : RGBA(r: 0, g: 0, b: 0, a: 1),
            shape: .pill
        )
        color = preset == .instagramLight ? RGBA(r: 0, g: 0, b: 0, a: 1) : RGBA()
        shadow.enabled = false
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        let base = fontName == Self.systemBoldFontName
            ? NSFont.systemFont(ofSize: size)
            : NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        return Self.font(base, size: size, bold: isBold, italic: isItalic)
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
        p.lineHeightMultiple = CGFloat(clampedLineHeightMultiple)
        return p
    }

    var clampedLineHeightMultiple: Double {
        guard lineHeightMultiple.isFinite else { return 1 }
        return min(max(lineHeightMultiple, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
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
            attrs[.strokeWidth] = NSNumber(value: -border.clampedWidth)
            if includeColor { attrs[.strokeColor] = border.color.nsColor }
        }
        return attrs
    }

    func strokeInset(fontSize: CGFloat) -> CGFloat {
        guard border.enabled, border.clampedWidth > 0 else { return 0 }
        return ceil(fontSize * CGFloat(border.clampedWidth / 100))
    }

    private static func font(_ font: NSFont, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits = CTFontGetSymbolicTraits(font as CTFont)
        if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        if italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }

        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        let descriptor = CTFontCopyFontDescriptor(font as CTFont)
        guard let resolvedDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, traits, mask) else {
            return font
        }
        return CTFontCreateWithFontDescriptor(resolvedDescriptor, size, nil) as NSFont
    }

    private static func symbolicTraits(fontName: String, size: CGFloat) -> CTFontSymbolicTraits {
        guard let font = NSFont(name: fontName, size: size) else { return [] }
        return CTFontGetSymbolicTraits(font as CTFont)
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
