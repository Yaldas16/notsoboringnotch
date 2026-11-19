import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GPTImageAttachment: Identifiable, Equatable, Sendable {
    enum Failure: LocalizedError, Equatable, Sendable {
        case unsupported, unreadable, tooLarge, animated, tooMany, captureFailed, capturePermission

        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose a PNG, JPEG, WebP, HEIC, TIFF, or still GIF image."
            case .unreadable: "The image could not be read. Try saving it as a PNG or JPEG."
            case .tooLarge: "This image is too large. Choose an image under 25 MB and 80 megapixels."
            case .animated: "Choose a still image. Animated and multipage files aren’t supported."
            case .tooMany: "Attach up to four images per message."
            case .captureFailed: "The selected area couldn’t be captured. Try selecting it again."
            case .capturePermission: "Allow NotSoBoringNotch under Privacy & Security → Screen & System Audio Recording to capture an area."
            }
        }
    }

    static let acceptedTypes: [UTType] = [.png, .jpeg, .webP, .gif, .heic, .heif, .tiff]
    static let maxDraftImages = 4
    static let maxSourceBytes = 25 * 1024 * 1024
    static let maxConversationImageBytes = 24 * 1024 * 1024
    private static let maxEncodedBytes = 4 * 1024 * 1024

    let id = UUID()
    let bytes: Data
    let mimeType: String
    let width: Int
    let height: Int
    let preview: CGImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var dataURL: String { "data:\(mimeType);base64,\(bytes.base64EncodedString())" }

    static func load(file url: URL) throws -> Self {
        guard url.isFileURL else { throw Failure.unsupported }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { throw Failure.unreadable }
        guard size <= maxSourceBytes else { throw Failure.tooLarge }
        guard let file = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maxSourceBytes + 1) else { throw Failure.unreadable }
        return try load(data: data)
    }

    static func load(data: Data) throws -> Self {
        guard data.count <= maxSourceBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              acceptedTypes.contains(type) else { throw Failure.unsupported }
        guard CGImageSourceGetCount(source) == 1 else { throw Failure.animated }
        guard let dimensions = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = dimensions[kCGImagePropertyPixelWidth] as? Int,
              let height = dimensions[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure.unreadable }
        guard width <= 16_384, height <= 16_384, width * height <= 80_000_000 else { throw Failure.tooLarge }
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw Failure.unreadable }
        return try encode(oriented, prefersLossless: type != .jpeg && type != .heic && type != .heif)
    }

    static func load(capture: CGImage) throws -> Self {
        guard let bounded = reduced(capture, longestEdge: 2_048) else { throw Failure.unreadable }
        return try encode(bounded, prefersLossless: true)
    }

    private static func encode(_ image: CGImage, prefersLossless: Bool) throws -> Self {
        let containsAlpha: Bool
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: containsAlpha = true
        default: containsAlpha = false
        }

        if prefersLossless || containsAlpha {
            if let png = encoded(image, as: .png), png.count <= maxEncodedBytes {
                return try attachment(bytes: png, type: .png, image: image)
            }
            if containsAlpha {
                guard let smaller = reduced(image, longestEdge: 900),
                      let png = encoded(smaller, as: .png), png.count <= maxEncodedBytes else { throw Failure.tooLarge }
                return try attachment(bytes: png, type: .png, image: smaller)
            }
        }
        guard let jpeg = encoded(image, as: .jpeg), jpeg.count <= maxEncodedBytes else { throw Failure.tooLarge }
        return try attachment(bytes: jpeg, type: .jpeg, image: image)
    }

    private static func attachment(bytes: Data, type: UTType, image: CGImage) throws -> Self {
        guard let preview = reduced(image, longestEdge: 320) else { throw Failure.unreadable }
        return Self(bytes: bytes, mimeType: type == .png ? "image/png" : "image/jpeg",
                    width: image.width, height: image.height, preview: preview)
    }

    private static func encoded(_ image: CGImage, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary : nil
        CGImageDestinationAddImage(encoder, image, properties)
        return CGImageDestinationFinalize(encoder) ? data as Data : nil
    }

    private static func reduced(_ image: CGImage, longestEdge: Int) -> CGImage? {
        let largest = max(image.width, image.height)
        if largest <= longestEdge { return image }
        let scale = Double(longestEdge) / Double(largest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let alpha = image.alphaInfo
        let bitmap: CGImageAlphaInfo = alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst
            ? .noneSkipLast : .premultipliedLast
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: color, bitmapInfo: bitmap.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
