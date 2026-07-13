import AppKit
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable {
    var fontName: String = "Helvetica-Bold"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    /// 1.0 = the font's natural line height. Instagram's text tool uses ~0.912.
    var lineHeightMultiple: Double = 1.0
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
    var shadow: Shadow = Shadow()
    var background: Background = Background()
    /// Kept under the legacy `border` key so existing project files continue
    /// to decode, but this now represents an outline around each glyph.
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

    struct Stroke: Codable, Sendable, Equatable {
        static let defaultWidth: Double = 3
        static let widthRange: ClosedRange<Double> = 0...20

        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        /// Core Text stroke width as a percentage of the rendered font size.
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

        /// Legacy border objects only stored enabled/color.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                width: (try? c.decode(Double.self, forKey: .width)) ?? Stroke.defaultWidth
            )
        }

        var clampedWidth: Double {
            guard width.isFinite else { return Stroke.defaultWidth }
            return min(max(width, Stroke.widthRange.lowerBound), Stroke.widthRange.upperBound)
        }
    }

    /// Instagram-style per-line pill behind the text. Padding and corner radius
    /// are fractions of the rendered font size so the pill scales with the text.
    struct Background: Codable, Sendable, Equatable {
        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        var paddingH: Double = Background.defaultPaddingH
        var paddingV: Double = Background.defaultPaddingV
        var cornerRadius: Double = Background.defaultCornerRadius

        // Calibrated against Instagram's native text tool (see fork notes).
        static let defaultPaddingH: Double = 0.35
        static let defaultPaddingV: Double = 0.435
        static let defaultCornerRadius: Double = 0.22

        private enum CodingKeys: String, CodingKey {
            case enabled, color, paddingH, paddingV, cornerRadius
        }

        init(
            enabled: Bool = false,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6),
            paddingH: Double = Background.defaultPaddingH,
            paddingV: Double = Background.defaultPaddingV,
            cornerRadius: Double = Background.defaultCornerRadius
        ) {
            self.enabled = enabled
            self.color = color
            self.paddingH = paddingH
            self.paddingV = paddingV
            self.cornerRadius = cornerRadius
        }

        /// Missing-key-tolerant: decodes the legacy `Fill {enabled, color}` shape.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 0.6),
                paddingH: (try? c.decode(Double.self, forKey: .paddingH)) ?? Background.defaultPaddingH,
                paddingV: (try? c.decode(Double.self, forKey: .paddingV)) ?? Background.defaultPaddingV,
                cornerRadius: (try? c.decode(Double.self, forKey: .cornerRadius)) ?? Background.defaultCornerRadius
            )
        }
    }

    /// Source-compatible name for callers written before backgrounds gained
    /// Instagram pill geometry. Project JSON continues to use `background`.
    typealias Fill = Background

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, lineHeightMultiple, color, alignment, shadow, background, border
    }
}

extension TextStyle {
    enum Preset: String, CaseIterable, Sendable {
        case instagramLight
        case instagramDark
    }

    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontName: (try? c.decode(String.self, forKey: .fontName)) ?? "Helvetica-Bold",
            fontSize: (try? c.decode(Double.self, forKey: .fontSize)) ?? 96,
            fontScale: (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.0,
            lineHeightMultiple: (try? c.decode(Double.self, forKey: .lineHeightMultiple)) ?? 1.0,
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
    /// Sentinel resolved through NSFont.boldSystemFont — the system SF Pro
    /// Bold has no public PostScript name to persist.
    static let systemBoldFontName = "SF Pro Bold"

    /// Instagram's text tool spacing, measured against a native overlay:
    /// baseline-to-baseline ≈ 0.912 × SF Pro's natural line height.
    static let instagramLineHeightMultiple = 0.912

    mutating func apply(_ preset: Preset) {
        fontName = TextStyle.systemBoldFontName
        lineHeightMultiple = TextStyle.instagramLineHeightMultiple
        background = TextStyle.Background(
            enabled: true,
            color: preset == .instagramLight
                ? TextStyle.RGBA()
                : TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)
        )
        color = preset == .instagramLight
            ? TextStyle.RGBA(r: 0, g: 0, b: 0, a: 1)
            : TextStyle.RGBA()
        shadow.enabled = false
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        if fontName == TextStyle.systemBoldFontName {
            return NSFont.boldSystemFont(ofSize: size)
        }
        return NSFont(name: fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
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
        if abs(lineHeightMultiple - 1.0) > 0.0001 {
            p.lineHeightMultiple = CGFloat(lineHeightMultiple)
        }
        return p
    }

    /// CATextLayer ignores paragraph-style line height, and the explicit
    /// CoreText path guarantees identical outlined glyphs in preview/export.
    /// render through the CoreText glyph path (which also draws the pill from
    /// the same CTFrame, keeping background and glyphs in exact register).
    var needsCoreTextRendering: Bool {
        background.enabled || border.enabled || abs(lineHeightMultiple - 1.0) > 0.0001
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

    /// Conservative layout inset that prevents thick CoreText outlines from
    /// being clipped at the edges of the editable text box.
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
