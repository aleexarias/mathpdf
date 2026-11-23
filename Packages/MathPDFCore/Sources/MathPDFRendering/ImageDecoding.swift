import CoreGraphics
import Foundation
import ImageIO

/// Stored images as drawable images, upright: a stored photo can carry its
/// orientation.
enum ImageDecoding {
    /// At most `longestSide` pixels on its longer side, or at full size. At
    /// full size, an image that needn't turn keeps its encoding, so a JPEG
    /// can go into an exported PDF as it is.
    static func upright(_ data: Data, longestSide: Int? = nil) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        if longestSide == nil, orientation == 1 {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide
                ?? max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary)
    }
}
