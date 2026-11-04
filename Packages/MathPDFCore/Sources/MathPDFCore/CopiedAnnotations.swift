import Foundation

/// The annotations of copied pages, as they go on the clipboard. The pages
/// themselves go beside them as a PDF.
public enum CopiedAnnotations {
    private static let version = 1

    private struct Payload: Codable {
        var version: Int
        var pageCount: Int
        var annotations: [Annotation]
    }

    public static func encode(_ annotations: [Annotation], pageCount: Int)
        throws -> Data
    {
        try StoreFile.makeEncoder().encode(
            Payload(
                version: version, pageCount: pageCount,
                annotations: annotations))
    }

    /// Nil for anything this version can't read.
    public static func decode(_ data: Data)
        -> (pageCount: Int, annotations: [Annotation])?
    {
        guard
            let payload = try? StoreFile.makeDecoder().decode(
                Payload.self, from: data),
            payload.version == version
        else { return nil }
        return (payload.pageCount, payload.annotations)
    }
}
