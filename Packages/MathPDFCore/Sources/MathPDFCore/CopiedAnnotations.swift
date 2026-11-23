import Foundation

/// The annotations of copied pages, as they go on the clipboard. The pages
/// themselves go beside them as a PDF.
///
/// Versions: 1 has the annotations; 2 adds the files of their images, by
/// hash, so pasting into another data folder still has them. A version 1
/// payload is a valid version 2 payload.
public enum CopiedAnnotations {
    private static let version = 2

    private struct Payload: Codable {
        var version: Int
        var pageCount: Int
        var annotations: [Annotation]
        var images: [String: Data]?
    }

    public static func encode(
        _ annotations: [Annotation], pageCount: Int,
        images: [String: Data] = [:]
    ) throws -> Data {
        try StoreFile.makeEncoder().encode(
            Payload(
                version: version, pageCount: pageCount,
                annotations: annotations, images: images.isEmpty ? nil : images
            ))
    }

    /// Nil for anything this version can't read.
    public static func decode(_ data: Data) -> (
        pageCount: Int, annotations: [Annotation], images: [String: Data]
    )? {
        guard
            let payload = try? StoreFile.makeDecoder().decode(
                Payload.self, from: data),
            (1...version).contains(payload.version)
        else { return nil }
        return (payload.pageCount, payload.annotations, payload.images ?? [:])
    }
}
