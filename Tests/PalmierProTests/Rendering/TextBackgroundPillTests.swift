import AppKit
import CoreText
import Testing
@testable import PalmierPro

@Suite("Text background pill")
struct TextBackgroundPillTests {
    private static func attributed(_ text: String, style: TextStyle, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: style.attributes(size: size))
    }

    private static func pillStyle() -> TextStyle {
        var style = TextStyle()
        style.alignment = .center
        style.background.enabled = true
        style.background.shape = .pill
        return style
    }

    @Test func singleLinePathUsesTextMetricsAndPadding() throws {
        let style = Self.pillStyle()
        let fontSize: CGFloat = 60
        let area = CGRect(x: 10, y: 20, width: 600, height: 200)
        let attributed = Self.attributed("Hello", style: style, size: fontSize)
        let path = try #require(TextBackgroundPath.path(
            for: attributed,
            textArea: area,
            fontSize: fontSize,
            background: style.background
        ))
        let box = path.boundingBox
        let font = style.resolvedFont(size: fontSize)
        let expectedHeight = font.ascender - font.descender
            + 2 * fontSize * CGFloat(style.background.clampedPaddingV)
        let expectedWidth = attributed.size().width
            + 2 * fontSize * CGFloat(style.background.clampedPaddingH)

        #expect(abs(box.height - expectedHeight) < 2)
        #expect(abs(box.width - expectedWidth) < 3)
        #expect(abs(box.midX - area.midX) < 2)
    }

    @Test func differentLineWidthsProducePerLineExtents() throws {
        let style = Self.pillStyle()
        let fontSize: CGFloat = 60
        let path = try #require(TextBackgroundPath.path(
            for: Self.attributed("A much much longer first line\nshort", style: style, size: fontSize),
            textArea: CGRect(x: 0, y: 0, width: 900, height: 400),
            fontSize: fontSize,
            background: style.background
        ))
        let box = path.boundingBox
        let probeY = box.maxY - 4
        let hits = stride(from: box.minX, through: box.maxX, by: 2).filter {
            path.contains(CGPoint(x: $0, y: probeY))
        }
        let shortLineWidth = (hits.max() ?? 0) - (hits.min() ?? 0)

        #expect(shortLineWidth > 10)
        #expect(shortLineWidth < box.width * 0.7)
    }

    @Test func blankLineSplitsPillIntoSeparateBlobs() throws {
        let style = Self.pillStyle()
        let path = try #require(TextBackgroundPath.path(
            for: Self.attributed("top\n\nbottom", style: style, size: 50),
            textArea: CGRect(x: 0, y: 0, width: 600, height: 500),
            fontSize: 50,
            background: style.background
        ))
        let box = path.boundingBox
        let hasEmptyBand = stride(from: box.minY, through: box.maxY, by: 2).contains { y in
            !stride(from: box.minX, through: box.maxX, by: 4).contains {
                path.contains(CGPoint(x: $0, y: y))
            }
        }

        #expect(hasEmptyBand)
    }

    @Test func finiteTextAreaNeverAddsLowerTabAtInstagramSizes() throws {
        for fontSize: CGFloat in [24, 42, 60, 96, 180, 300] {
            var style = Self.pillStyle()
            style.fontName = TextStyle.systemBoldFontName
            style.fontSize = Double(fontSize)
            style.lineHeightMultiple = TextStyle.instagramLineHeightMultiple

            for word in ["Here's", "Here’s"] {
                let visibleWord = String(word.dropLast())
                let full = Self.attributed(word, style: style, size: fontSize)
                let visible = Self.attributed(visibleWord, style: style, size: fontSize)
                let line = CTLineCreateWithAttributedString(full)
                let width = floor(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
                let height = ceil(visible.boundingRect(
                    with: CGSize(width: 10_000, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height) + 1
                let area = CGRect(x: 0, y: 0, width: width, height: height)
                let fullPath = try #require(TextBackgroundPath.path(
                    for: full,
                    textArea: area,
                    fontSize: fontSize,
                    lineHeightMultiple: CGFloat(style.lineHeightMultiple),
                    background: style.background
                ))
                let visiblePath = try #require(TextBackgroundPath.path(
                    for: visible,
                    textArea: area,
                    fontSize: fontSize,
                    lineHeightMultiple: CGFloat(style.lineHeightMultiple),
                    background: style.background
                ))

                #expect(
                    abs(fullPath.boundingBox.maxY - visiblePath.boundingBox.maxY) < 1,
                    "finite glyph height must prevent a lower pill tab at \(fontSize)pt"
                )
                #expect(abs(fullPath.boundingBox.height - visiblePath.boundingBox.height) < 1)
            }
        }
    }

    @Test func emptyOrCollapsedTextAreaYieldsNoPath() {
        let style = Self.pillStyle()
        let attributed = Self.attributed("Hello", style: style, size: 40)

        #expect(TextBackgroundPath.path(
            for: NSAttributedString(string: ""),
            textArea: CGRect(x: 0, y: 0, width: 100, height: 100),
            fontSize: 40,
            background: style.background
        ) == nil)
        #expect(TextBackgroundPath.path(
            for: attributed,
            textArea: CGRect(x: 0, y: 0, width: 100, height: 1),
            fontSize: 40,
            background: style.background
        ) == nil)
    }
}
