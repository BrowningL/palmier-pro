import CoreImage
import Foundation
import Vision

/// Experimental on-device foreground removal backed by Vision segmentation.
/// Exact-frame mattes are bounded and cached so repeated preview/export renders reuse them.
enum PersonKeyKernel {
    private static let kernel = CIKernelLoader.colorKernel("PersonKey", "personKey")
    private static let matteCache = PersonMatteCache()

    enum CutoutMode: Int {
        case person = 0
        case subject = 1
        case union = 2

        init(param: Double) {
            self = CutoutMode(rawValue: min(2, max(0, Int(param.rounded())))) ?? .subject
        }
    }

    static func invalidateCache() {
        matteCache.removeAllObjects()
    }

    static func apply(
        _ image: CIImage,
        strength: Double,
        feather: Double,
        shift: Double,
        mode: Double,
        quality: Double,
        cacheKey: String
    ) -> CIImage {
        guard kernel != nil, strength > 0 else { return image }
        let extent = image.extent
        guard extent.width >= 32, extent.height >= 32, !extent.isInfinite, !extent.isEmpty else { return image }
        guard let matte = matte(
            for: image,
            mode: CutoutMode(param: mode),
            quality: quality,
            cacheKey: cacheKey
        ) else { return image }
        let mask = shaped(matte, extent: extent, feather: feather, shift: shift)
        return applyMask(image, mask: mask, strength: strength)
    }

    static func applyMask(_ image: CIImage, mask: CIImage, strength: Double) -> CIImage {
        guard let kernel, strength > 0 else { return image }
        return kernel.apply(
            extent: image.extent,
            arguments: [image, mask, Float(min(1, strength))]
        ) ?? image
    }

    static func shaped(_ matte: CIImage, extent: CGRect, feather: Double, shift: Double) -> CIImage {
        var mask = matte.transformed(by: CGAffineTransform(
            scaleX: extent.width / matte.extent.width,
            y: extent.height / matte.extent.height
        ))
        let shiftPixels = min(10, max(-10, shift * 10))
        if shiftPixels <= -0.5 {
            mask = mask.clampedToExtent().applyingFilter(
                "CIMorphologyMinimum",
                parameters: [kCIInputRadiusKey: -shiftPixels]
            )
        } else if shiftPixels >= 0.5 {
            mask = mask.clampedToExtent().applyingFilter(
                "CIMorphologyMaximum",
                parameters: [kCIInputRadiusKey: shiftPixels]
            )
        }
        let featherPixels = min(12, max(0, feather * 12))
        if featherPixels >= 0.1 {
            mask = mask.clampedToExtent().applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: featherPixels]
            )
        }
        return mask.cropped(to: CGRect(origin: .zero, size: extent.size))
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
    }

    private static func matte(
        for image: CIImage,
        mode: CutoutMode,
        quality: Double,
        cacheKey: String
    ) -> CIImage? {
        let extent = image.extent
        let key = "\(cacheKey):m\(mode.rawValue):q\(Int(quality.rounded())):" +
            "\(Int(extent.origin.x)),\(Int(extent.origin.y)),\(Int(extent.width))x\(Int(extent.height))" as NSString
        if let cached = matteCache.object(forKey: key) { return cached }

        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))
        let matte: CIImage?
        switch mode {
        case .person:
            matte = personMatte(normalized, quality: quality)
        case .subject:
            matte = subjectMatte(normalized, quality: quality)
        case .union:
            let person = personMatte(normalized, quality: quality)
            let subject = subjectMatte(normalized, quality: quality)
            switch (person, subject) {
            case (let person?, let subject?):
                let size = normalized.extent.size
                matte = scaled(person, to: size).applyingFilter(
                    "CIMaximumCompositing",
                    parameters: [kCIInputBackgroundImageKey: scaled(subject, to: size)]
                )
            case (let person?, nil): matte = person
            case (nil, let subject?): matte = subject
            case (nil, nil): matte = nil
            }
        }
        guard let matte else { return nil }
        matteCache.setObject(matte, forKey: key)
        return matte
    }

    private static func personMatte(_ image: CIImage, quality: Double) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = switch Int(quality.rounded()) {
        case 0: .fast
        case 2: .accurate
        default: .balanced
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    }

    private static func subjectMatte(_ image: CIImage, quality: Double) -> CIImage? {
        let maxDimension: CGFloat = switch Int(quality.rounded()) {
        case 0: 512
        case 2: 2048
        default: 1024
        }
        let dimension = max(image.extent.width, image.extent.height)
        let input = dimension > maxDimension
            ? image.transformed(by: CGAffineTransform(scaleX: maxDimension / dimension, y: maxDimension / dimension))
            : image
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: input, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // A per-frame Vision miss is not evidence that the whole frame is
        // background. Fail open so detection instability cannot flash a clip away.
        guard let observation = request.results?.first else { return nil }
        guard let buffer = try? observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        ) else { return nil }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    }

    private static func scaled(_ matte: CIImage, to size: CGSize) -> CIImage {
        matte.transformed(by: CGAffineTransform(
            scaleX: size.width / matte.extent.width,
            y: size.height / matte.extent.height
        ))
    }
}

private final class PersonMatteCache: @unchecked Sendable {
    private let cache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 64
        return cache
    }()

    func object(forKey key: NSString) -> CIImage? { cache.object(forKey: key) }
    func setObject(_ image: CIImage, forKey key: NSString) { cache.setObject(image, forKey: key) }
    func removeAllObjects() { cache.removeAllObjects() }
}
