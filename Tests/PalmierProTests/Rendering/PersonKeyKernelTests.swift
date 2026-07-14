import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("PersonKeyKernel")
struct PersonKeyKernelTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    @Test func zeroStrengthIsGuaranteedPassthrough() {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = PersonKeyKernel.apply(
            input, strength: 0, feather: 0.1, shift: 0, mode: 1, quality: 1, cacheKey: "test"
        )
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        #expect(abs(Double(pixel[3]) - 1) < 0.01)
    }

    @Test func subjectDetectionMissFailsOpen() {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = PersonKeyKernel.apply(
            input, strength: 1, feather: 0, shift: 0, mode: 1, quality: 0,
            cacheKey: "no-subject-\(UUID().uuidString)"
        )
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        #expect(abs(Double(pixel[3]) - 1) < 0.01)
    }

    @Test func shapedMatteScalesAndSupportsEdgeShift() {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 8))
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let matte = white.composited(over: black)
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)

        func luma(_ image: CIImage, x: CGFloat) -> Double {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(
                image, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: x, y: 8, width: 1, height: 1), format: .RGBAf, colorSpace: nil
            )
            return Double(pixel[0])
        }

        let plain = PersonKeyKernel.shaped(matte, extent: extent, feather: 0, shift: 0)
        #expect(luma(plain, x: 3) > 0.9)
        #expect(luma(plain, x: 13) < 0.1)
        #expect(luma(PersonKeyKernel.shaped(matte, extent: extent, feather: 0, shift: 1), x: 13) > 0.9)
        #expect(luma(PersonKeyKernel.shaped(matte, extent: extent, feather: 0, shift: -1), x: 3) < 0.1)
    }

    @Test func descriptorSnapsDiscreteModeAndQuality() throws {
        let descriptor = try #require(EffectRegistry.descriptor(id: "key.person"))
        var effect = descriptor.makeEffect()
        effect.params["mode"] = EffectParam(value: 1.7)
        effect.params["quality"] = EffectParam(value: 0.4)
        let params = descriptor.resolve(effect, atOffset: 0)
        #expect(params.value("mode") == 2)
        #expect(params.value("quality") == 0)
    }

    @Test func matteEdgeIsPremultipliedExactlyOnceByFramePipeline() {
        let extent = CGRect(x: 0, y: 0, width: 8, height: 8)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
        let halfMask = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let keyed = PersonKeyKernel.applyMask(red, mask: halfMask, strength: 1)
            .premultiplyingAlpha()
        var pixel = [Float](repeating: 0, count: 4)
        context.render(
            keyed, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: nil
        )
        #expect(abs(Double(pixel[0]) - 0.5) < 0.05)
        #expect(abs(Double(pixel[3]) - 0.5) < 0.05)
    }
}
