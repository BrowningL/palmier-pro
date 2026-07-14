import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("LumaKeyKernel")
struct LumaKeyKernelTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    private func alpha(brightness: Double, dark: Bool, threshold: Double, softness: Double) -> Double {
        let input = CIImage(color: CIColor(red: brightness, green: brightness, blue: brightness))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let output = dark
            ? LumaKeyKernel.applyDark(input, threshold: threshold, softness: softness)
            : LumaKeyKernel.apply(input, threshold: threshold, softness: softness)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        return Double(pixel[3])
    }

    @Test func brightKeyRemovesWhiteAndKeepsDarkPixels() {
        #expect(alpha(brightness: 1, dark: false, threshold: 0.9, softness: 0.08) < 0.05)
        #expect(alpha(brightness: 0.2, dark: false, threshold: 0.9, softness: 0.08) > 0.95)
    }

    @Test func darkKeyRemovesBlackAndKeepsBrightPixels() {
        #expect(alpha(brightness: 0, dark: true, threshold: 0.12, softness: 0.08) < 0.05)
        #expect(alpha(brightness: 0.8, dark: true, threshold: 0.12, softness: 0.08) > 0.95)
    }

    @Test func neutralThresholdsAreNoOps() {
        #expect(alpha(brightness: 1, dark: false, threshold: 1, softness: 0.1) > 0.95)
        #expect(alpha(brightness: 0, dark: true, threshold: 0, softness: 0.1) > 0.95)
        #expect(alpha(brightness: 0.5, dark: false, threshold: 0, softness: 0.1) < 0.05)
        #expect(alpha(brightness: 0.5, dark: true, threshold: 1, softness: 0.1) < 0.05)
    }

    @Test func softEdgeIsPremultipliedExactlyOnceByFramePipeline() {
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        // Red luma (0.2126) is the midpoint of this soft transition, so keep ≈ 0.5.
        let keyed = LumaKeyKernel.apply(red, threshold: 0.3, softness: 0.1748)
            .premultiplyingAlpha()
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            keyed, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        #expect(abs(Double(pixel[0]) - 0.5) < 0.08)
        #expect(abs(Double(pixel[3]) - 0.5) < 0.08)
    }
}
