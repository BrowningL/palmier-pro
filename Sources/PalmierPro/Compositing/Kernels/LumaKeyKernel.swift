import CoreImage
import Foundation

/// Bright- and dark-background luma keys. Kernel: `Metal/LumaKey.metal`.
enum LumaKeyKernel {
    private static let brightKernel = CIKernelLoader.colorKernel("LumaKey", "lumaKey")
    private static let darkKernel = CIKernelLoader.colorKernel("LumaKey", "lumaDarkKey")

    static func apply(_ image: CIImage, threshold: Double, softness: Double) -> CIImage {
        guard let brightKernel, threshold < 1 else { return image }
        return brightKernel.apply(
            extent: image.extent,
            arguments: [image, Float(threshold), Float(softness)]
        ) ?? image
    }

    static func applyDark(_ image: CIImage, threshold: Double, softness: Double) -> CIImage {
        guard let darkKernel, threshold > 0 else { return image }
        return darkKernel.apply(
            extent: image.extent,
            arguments: [image, Float(threshold), Float(softness)]
        ) ?? image
    }
}
