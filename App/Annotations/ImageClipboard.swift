import AppKit
import UniformTypeIdentifiers

/// Where an image to add comes from.
enum ImageSource: Sendable {
    case data(Data)
    case file(URL)
}

/// An image on the clipboard, to add to a page. Nothing counts beside a PDF,
/// which is left alone though it usually comes with a picture of itself too,
/// and a copied file counts only if it's an image, not by the icon that comes
/// with it.
///
/// Only the types are looked at before the user pastes: reading what's on the
/// clipboard otherwise needs their permission, so whether a copied file is an
/// image is found out when it's pasted.
enum ImageClipboard {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init(UTType.jpeg.identifier),
        .init(UTType.heic.identifier),
    ]

    static func hasImage(in pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [.pdf]) == nil
            && pasteboard.availableType(from: [.fileURL] + imageTypes) != nil
    }

    static func read(from pasteboard: NSPasteboard = .general)
        -> ImageSource?
    {
        guard hasImage(in: pasteboard) else { return nil }
        if pasteboard.availableType(from: [.fileURL]) != nil {
            return imageFile(in: pasteboard).map(ImageSource.file)
        }
        // in the order the copying app gave them: the types macOS adds
        // itself come after, and a TIFF made from a JPEG can be ten times
        // its size
        return pasteboard.types?.first(where: imageTypes.contains)
            .flatMap(pasteboard.data(forType:)).map(ImageSource.data)
    }

    private static func imageFile(in pasteboard: NSPasteboard) -> URL? {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard urls.count == 1,
            let type = try? urls[0].resourceValues(forKeys: [.contentTypeKey])
                .contentType,
            type.conforms(to: .image)
        else { return nil }
        return urls[0]
    }
}
