import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to store: its size checked, its metadata (location, camera,
/// dates) gone, in a format kept small.
public struct PreparedImage: Equatable, Sendable {
    public let data: Data
    /// SHA-256 of `data`, the name it's stored under.
    public let hash: String
    /// Of the upright image. A JPEG or HEIC keeps its orientation, so drawing
    /// it applies that.
    public let pixelSize: CGSize
}

/// The types images are stored as, and the extensions their files have.
enum StoredImageType {
    static let all: [(type: UTType, fileExtension: String)] = [
        (.png, "png"), (.jpeg, "jpg"), (.heic, "heic"),
    ]

    /// Told by the contents; nil for any other type.
    static func fileExtension(of data: Data) -> String? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source).flatMap({
                UTType($0 as String)
            })
        else { return nil }
        return all.first { type.conforms(to: $0.type) }?.fileExtension
    }
}

public enum ImageImportProblem: Error, Equatable, LocalizedError {
    case notAnImage
    case fileTooLarge
    case tooManyPixels
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notAnImage: "That isn't an image mathpdf can add."
        case .fileTooLarge:
            "The image is larger than \(ImageImport.largestFile / 1_000_000) MB."
        case .tooManyPixels:
            """
            The image has more than \(ImageImport.mostPixels / 1_000_000) \
            megapixels.
            """
        case .unreadable: "The image couldn't be read."
        }
    }
}

/// Turns image data from the clipboard or a file into what's stored. Sizes are
/// checked before anything is decoded, as a small file can claim to be any
/// size.
public enum ImageImport {
    static let largestFile = 50_000_000
    /// Re-encoding holds the whole image in memory, four bytes a pixel.
    static let mostPixels = 50_000_000

    private static let readable: [UTType] = [
        .png, .jpeg, .heic, .heif, .tiff, .gif, .bmp, .webP,
    ]
    /// Kept as encoded, as re-encoding them would lose quality. The rest are
    /// stored as PNG: lossless, and much smaller than the TIFF that
    /// screenshots arrive as on the clipboard.
    private static let keptAsEncoded: [UTType] = [.jpeg, .heic]

    /// An image file, its size checked before it's read.
    public static func prepare(contentsOf url: URL) throws(ImageImportProblem)
        -> PreparedImage
    {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { throw .unreadable }
        guard size <= largestFile else { throw .fileTooLarge }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try prepare(data)
    }

    public static func prepare(_ data: Data) throws(ImageImportProblem)
        -> PreparedImage
    {
        guard data.count <= largestFile else { throw .fileTooLarge }
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source).flatMap({
                UTType($0 as String)
            }),
            readable.contains(where: type.conforms(to:)),
            CGImageSourceGetCount(source) > 0
        else { throw .notAnImage }
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw .unreadable }
        guard width * height <= mostPixels else { throw .tooManyPixels }

        let orientation =
            properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5 to 8 turn the image a quarter
        let pixelSize =
            (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let kept = keptAsEncoded.first(where: type.conforms(to:))
        guard
            let stored = kept.flatMap({
                withoutMetadata(source, type: $0, orientation: orientation)
            }) ?? uprightPNG(source, longestSide: max(width, height))
        else { throw .unreadable }
        return PreparedImage(
            data: stored, hash: sha256Hex(stored), pixelSize: pixelSize)
    }

    /// The same encoded image, its metadata replaced by just its
    /// orientation.
    private static func withoutMetadata(
        _ source: CGImageSource, type: UTType, orientation: UInt32
    ) -> Data? {
        let data = NSMutableData()
        let metadata = CGImageMetadataCreateMutable()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil),
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary,
                kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        guard
            CGImageDestinationCopyImageSource(
                destination, source, options as CFDictionary, nil)
        else { return nil }
        return data as Data
    }

    /// The first frame, upright, in RGB or grey, with its colour profile and
    /// nothing else.
    private static func uprightPNG(_ source: CGImageSource, longestSide: Int)
        -> Data?
    {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary),
            let image = inRGBOrGrey(decoded)
        else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// PNG holds only RGB and grey: anything else, like CMYK, becomes sRGB.
    private static func inRGBOrGrey(_ image: CGImage) -> CGImage? {
        if let model = image.colorSpace?.model,
            model == .rgb || model == .monochrome
        {
            return image
        }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
