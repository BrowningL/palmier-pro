import AppKit
import CoreText
import Testing
@testable import PalmierPro

@MainActor
struct TextBackgroundPillTests {
    private static func attributed(_ text: String, style: TextStyle, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: style.attributes(size: size))
    }

    @Test func singleLinePathIsPaddedRoundedRect() throws {
        var style = TextStyle()
        style.alignment = .center
        style.background.enabled = true
        let fontSize: CGFloat = 60
        let area = CGRect(x: 10, y: 20, width: 600, height: 200)
        let path = try #require(TextBackgroundPath.path(
            for: Self.attributed("Hello", style: style, size: fontSize),
            textArea: area,
            fontSize: fontSize,
            background: style.background
        ))
        let box = path.boundingBox
        let font = style.resolvedFont(size: fontSize)
        let padV = fontSize * CGFloat(style.background.paddingV)
        let expectedHeight = font.ascender - font.descender + 2 * padV
        #expect(abs(box.height - expectedHeight) < 2)
        let textWidth = Self.attributed("Hello", style: style, size: fontSize).size().width
        let expectedWidth = textWidth + 2 * fontSize * CGFloat(style.background.paddingH)
        #expect(abs(box.width - expectedWidth) < 3)
        #expect(abs(box.midX - area.midX) < 2)
    }

    @Test func differentLineWidthsProduceDistinctPerLineExtents() throws {
        var style = TextStyle()
        style.alignment = .center
        style.background.enabled = true
        let fontSize: CGFloat = 60
        let area = CGRect(x: 0, y: 0, width: 900, height: 400)
        let path = try #require(TextBackgroundPath.path(
            for: Self.attributed("A much much longer first line\nshort", style: style, size: fontSize),
            textArea: area,
            fontSize: fontSize,
            background: style.background
        ))
        let box = path.boundingBox
        let probeY = box.maxY - 4
        var hits: [CGFloat] = []
        for x in stride(from: box.minX, through: box.maxX, by: 2)
            where path.contains(CGPoint(x: x, y: probeY)) {
            hits.append(x)
        }
        let bottomWidth = (hits.max() ?? 0) - (hits.min() ?? 0)
        #expect(bottomWidth > 10)
        #expect(bottomWidth < box.width * 0.7)
    }

    @Test func blankLineSplitsPillIntoSeparateBlobs() throws {
        var style = TextStyle()
        style.background.enabled = true
        let fontSize: CGFloat = 50
        let area = CGRect(x: 0, y: 0, width: 600, height: 500)
        let path = try #require(TextBackgroundPath.path(
            for: Self.attributed("top\n\nbottom", style: style, size: fontSize),
            textArea: area,
            fontSize: fontSize,
            background: style.background
        ))
        let box = path.boundingBox
        var emptyBandFound = false
        for y in stride(from: box.minY, through: box.maxY, by: 2) {
            var any = false
            for x in stride(from: box.minX, through: box.maxX, by: 4)
                where path.contains(CGPoint(x: x, y: y)) {
                any = true
                break
            }
            if !any {
                emptyBandFound = true
                break
            }
        }
        #expect(emptyBandFound)
    }

    @Test func finiteTextAreaOmitsInvisibleWrappedLineAtIGSizes() throws {
        for fontSize: CGFloat in [24, 60, 96, 180, 300] {
            var style = TextStyle()
            style.fontName = TextStyle.systemBoldFontName
            style.fontSize = Double(fontSize)
            style.lineHeightMultiple = TextStyle.instagramLineHeightMultiple
            style.background.enabled = true

            for word in ["Here's", "Here’s"] {
                let visibleWord = String(word.dropLast())
                let full = Self.attributed(word, style: style, size: fontSize)
                let visible = Self.attributed(visibleWord, style: style, size: fontSize)
                let fullLine = CTLineCreateWithAttributedString(full)
                let width = floor(CGFloat(CTLineGetTypographicBounds(fullLine, nil, nil, nil)))
                let oneLineHeight = ceil(visible.boundingRect(
                    with: CGSize(width: 10_000, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height) + 1
                let area = CGRect(x: 0, y: 0, width: width, height: oneLineHeight)

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
                    "The pill must not draw a lower tab for a line the finite glyph frame cannot display at \(fontSize) pt"
                )
                #expect(abs(fullPath.boundingBox.height - visiblePath.boundingBox.height) < 1)
            }
        }
    }

    @Test func emptyOrCollapsedTextAreaYieldsNoPath() {
        var style = TextStyle()
        style.background.enabled = true
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

    @Test func textClipLayerUsesPillInsteadOfAClipBoxFill() throws {
        var style = TextStyle()
        style.fontSize = 80
        style.shadow.enabled = false
        style.background = TextStyle.Background(
            enabled: true,
            color: TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1)
        )
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        clip.mediaType = .text
        clip.textContent = "PILL"
        clip.textStyle = style
        clip.transform = Transform(center: (0.5, 0.5), width: 0.8, height: 0.5)

        let layer = TextClipLayer.make(contentsScale: 1)
        layer.apply(clip: clip, containerSize: CGSize(width: 640, height: 360))
        let path = try #require(layer.pill.path)
        #expect(layer.backgroundColor == nil)
        #expect(path.boundingBox.width < layer.bounds.width)
        #expect(layer.glyphs.contents != nil)
    }
}
