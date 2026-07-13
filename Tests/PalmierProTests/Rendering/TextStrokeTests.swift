import AppKit
import Foundation
import Testing
@testable import PalmierPro

@Suite("Text glyph stroke")
@MainActor
struct TextStrokeTests {
    @Test func legacyBorderDefaultsToThreePercentStroke() throws {
        let json = """
        {
          "fontName": "Helvetica-Bold",
          "fontSize": 96,
          "border": {
            "enabled": true,
            "color": {"r": 0.1, "g": 0.2, "b": 0.3, "a": 0.9}
          }
        }
        """

        let style = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(style.border.enabled)
        #expect(style.border.color.g == 0.2)
        #expect(style.border.width == TextStyle.Stroke.defaultWidth)
    }

    @Test func strokePersistsUnderLegacyBorderKey() throws {
        var style = TextStyle()
        style.border = TextStyle.Stroke(
            enabled: true,
            color: TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1),
            width: 7.5
        )

        let data = try JSONEncoder().encode(style)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let border = try #require(object["border"] as? [String: Any])
        #expect((border["width"] as? NSNumber)?.doubleValue == 7.5)
        #expect(object["stroke"] == nil)
        #expect(try JSONDecoder().decode(TextStyle.self, from: data) == style)
    }

    @Test func attributedStrokeUsesNegativePercentWidth() throws {
        var style = TextStyle()
        style.border = TextStyle.Stroke(enabled: true, width: 8)
        let attrs = style.attributes(size: 100)

        let width = try #require(attrs[.strokeWidth] as? NSNumber)
        #expect(width.doubleValue == -8)
        #expect(attrs[.strokeColor] != nil)
    }

    @Test func naturalLayoutReservesStrokeInset() {
        var plain = TextStyle(fontSize: 100)
        plain.shadow.enabled = false
        var stroked = plain
        stroked.border = TextStyle.Stroke(enabled: true, width: 10)

        let plainSize = TextLayout.naturalSize(
            content: "STROKE", style: plain, maxWidth: 1_000, canvasHeight: 1_080
        )
        let strokedSize = TextLayout.naturalSize(
            content: "STROKE", style: stroked, maxWidth: 1_000, canvasHeight: 1_080
        )
        #expect(strokedSize.width >= plainSize.width + 20)
        #expect(strokedSize.height >= plainSize.height + 20)
    }

    @Test func rasterizedGlyphContainsFillAndStrokeWithoutClippedEdges() throws {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 30)
        clip.mediaType = .text
        clip.textContent = "MW"
        clip.transform = Transform(center: (0.5, 0.5), width: 0.9, height: 0.25)
        var style = TextStyle(fontName: "Helvetica-Bold", fontSize: 120)
        style.alignment = .left
        style.color = TextStyle.RGBA()
        style.shadow.enabled = false
        style.border = TextStyle.Stroke(
            enabled: true,
            color: TextStyle.RGBA(r: 1, g: 0, b: 0, a: 1),
            width: 8
        )
        clip.textStyle = style

        let layer = TextClipLayer.make(contentsScale: 1)
        layer.apply(clip: clip, containerSize: CGSize(width: 600, height: 1_080))
        let image = try #require(layer.glyphs.renderedImage)
        let pixels = rgbaPixels(image)
        var red = 0
        var white = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 100 {
            let r = pixels[i]
            let g = pixels[i + 1]
            let b = pixels[i + 2]
            if r > 180, g < 90, b < 90 { red += 1 }
            if r > 180, g > 180, b > 180 { white += 1 }
        }

        #expect(red > 100)
        #expect(white > 100)
        #expect(edgeAlphaCount(pixels, width: image.width, height: image.height) == 0)
        #expect(layer.borderColor == nil)
        #expect(layer.borderWidth == 0)
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private func edgeAlphaCount(_ pixels: [UInt8], width: Int, height: Int) -> Int {
        var count = 0
        for x in 0..<width {
            if pixels[x * 4 + 3] > 0 { count += 1 }
            if pixels[((height - 1) * width + x) * 4 + 3] > 0 { count += 1 }
        }
        for y in 1..<(height - 1) {
            if pixels[y * width * 4 + 3] > 0 { count += 1 }
            if pixels[(y * width + width - 1) * 4 + 3] > 0 { count += 1 }
        }
        return count
    }
}
