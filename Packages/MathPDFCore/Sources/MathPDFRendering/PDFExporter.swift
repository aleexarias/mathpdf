import AppKit
import MathPDFCore
import PDFKit

/// Writes a copy of a PDF with mathpdf's annotations in it, for other apps.
/// The original's pages, links and annotations are kept as they are; ours are
/// added as standard PDF annotations: highlights and underlines (one per item,
/// however many lines), sticky notes, text boxes as editable text, and each
/// formula, or text box with formulas, as a stamp that carries its drawing, so
/// other editors can show it and move it like an image, and each image as a
/// stamp showing it at full size. The original file is never written to.
@MainActor
public enum PDFExporter {
    public enum Failure: LocalizedError, Equatable {
        case unreadablePDF
        case locked
        case commentingNotAllowed
        case wouldReplaceOriginal
        case couldntBuild

        public var errorDescription: String? {
            switch self {
            case .unreadablePDF: "The PDF couldn't be read."
            case .locked:
                "The PDF is password-protected, so a copy can't be written."
            case .commentingNotAllowed:
                """
                The PDF's security settings don't allow annotations, so a \
                copy with them can't be written.
                """
            case .wouldReplaceOriginal:
                """
                That's the original PDF, which mathpdf never changes. Choose \
                another name.
                """
            case .couldntBuild: "The annotated PDF couldn't be put together."
            }
        }
    }

    /// The quick export's file: `<name>_annotated.pdf`, next to the original.
    public nonisolated static func quickExportURL(for original: URL) -> URL {
        let name = original.deletingPathExtension().lastPathComponent
        return original.deletingLastPathComponent().appending(
            path: "\(name)_annotated.pdf")
    }

    /// `images` are the images shown, at full size, by hash.
    static func annotatedDocument(
        original data: Data, annotations: [Annotation],
        images: [String: CGImage] = [:]
    ) throws(Failure) -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw .unreadablePDF
        }
        guard !document.isLocked else { throw .locked }
        // PDFKit would leave them out without saying so
        guard annotations.isEmpty || document.allowsCommenting else {
            throw .commentingNotAllowed
        }
        for (pageIndex, mark) in marks(
            for: annotations, in: document, images: images)
        {
            document.page(at: pageIndex)?.addAnnotation(mark)
        }
        return document
    }

    /// A document only the export uses, so it's safe to hand to another
    /// thread.
    private struct DocumentToWrite: @unchecked Sendable {
        let document: PDFDocument
    }

    /// Writes the annotated copy to `url` in one step: whatever was there
    /// before stays until the new file is complete. Never to `original`.
    /// Formulas are typeset here, on the main thread, but writing a big PDF
    /// takes seconds, so that happens off it, and so does decoding images.
    /// Returns how many images were left out, missing from `images`.
    @discardableResult
    public static func export(
        original data: Data, annotations: [Annotation], to url: URL,
        originalURL: URL?, images store: ImageStore?
    ) async throws -> Int {
        if let originalURL, isSameFile(url, originalURL) {
            throw Failure.wouldReplaceOriginal
        }
        let shown = annotations.compactMap { annotation -> String? in
            guard case .image(let image) = annotation.kind else { return nil }
            return image.hash
        }
        let images = await decoded(Set(shown), from: store)
        let job = DocumentToWrite(
            document: try annotatedDocument(
                original: data, annotations: annotations, images: images))
        try await Task.detached(priority: .userInitiated) {
            guard let output = job.document.dataRepresentation() else {
                throw Failure.couldntBuild
            }
            removeLeftoverTempFiles(for: url)
            try AtomicFile.write(output, to: url)
        }.value
        return shown.count { images[$0] == nil }
    }

    /// At full size; a missing or damaged image is left out.
    private nonisolated static func decoded(
        _ hashes: Set<String>, from store: ImageStore?
    ) async -> [String: CGImage] {
        guard let store else { return [:] }
        var images: [String: CGImage] = [:]
        for hash in hashes {
            if let data = await store.data(for: hash),
                let image = ImageDecoding.upright(data)
            {
                images[hash] = image
            }
        }
        return images
    }

    // MARK: Building

    /// Our annotations as PDF annotations, by page. The lines of a highlight
    /// or underline become one annotation, and so do a note's underlines.
    static func marks(
        for annotations: [Annotation], in document: PDFDocument,
        images: [String: CGImage]
    ) -> [(
        pageIndex: Int, mark: PDFAnnotation
    )] {
        func rotation(_ pageIndex: Int) -> Int {
            document.page(at: pageIndex)?.rotation ?? 0
        }
        let items = Dictionary(grouping: annotations, by: \.itemID)
        var done = Set<UUID>()
        var marks: [(pageIndex: Int, mark: PDFAnnotation)] = []
        for annotation in annotations
        where done.insert(annotation.itemID).inserted {
            let color = annotation.color.nsColor
            switch annotation.kind {
            case .highlight, .underline:
                let type: PDFAnnotationSubtype =
                    annotation.kind == .highlight ? .highlight : .underline
                // A selection can run onto the next page: each page gets an
                // annotation of its own.
                let byPage = Dictionary(
                    grouping: items[annotation.itemID] ?? [annotation],
                    by: \.pageIndex)
                for (page, lines) in byPage.sorted(by: { $0.key < $1.key }) {
                    marks.append(
                        (
                            page,
                            AnnotationMarks.markup(
                                type, lines.map(\.bounds), color,
                                pageRotation: rotation(page))
                        ))
                }
            case let .note(text, anchors):
                if !anchors.isEmpty {
                    marks.append(
                        (
                            annotation.pageIndex,
                            AnnotationMarks.markup(
                                .underline, anchors,
                                AnnotationMarks.anchorColor(for: color),
                                pageRotation: rotation(annotation.pageIndex))
                        ))
                }
                marks.append(
                    (
                        annotation.pageIndex,
                        AnnotationMarks.noteIcon(
                            annotation, text: text, color: color)
                    ))
            case .textBox, .latex:
                marks += AnnotationMarks.marks(
                    for: annotation,
                    pageRotation: rotation(annotation.pageIndex), images: nil
                ).map { (annotation.pageIndex, $0.mark) }
            case .image(let image):
                guard let decoded = images[image.hash] else { break }
                marks.append(
                    (
                        annotation.pageIndex,
                        ImageAnnotation(
                            bounds: annotation.bounds, image: image,
                            decoded: decoded,
                            pageRotation: rotation(annotation.pageIndex))
                    ))
            }
        }
        return marks
    }

    // MARK: Files

    /// Whether two URLs name the same file, however they're spelled, down to
    /// the case of a name on a case-insensitive disk.
    public nonisolated static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath()
            == b.standardizedFileURL.resolvingSymlinksInPath()
        {
            return true
        }
        let ids = [a, b].map {
            try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
        }
        guard let first = ids[0], let second = ids[1] else { return false }
        return first.isEqual(second)
    }

    private nonisolated static func removeLeftoverTempFiles(for url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = ".\(url.lastPathComponent)\(AtomicFile.tempMarker)"
        for name
            in (try? FileManager.default.contentsOfDirectory(
                atPath: folder.path)) ?? [] where name.hasPrefix(prefix)
        {
            try? FileManager.default.removeItem(
                at: folder.appending(path: name))
        }
    }
}
