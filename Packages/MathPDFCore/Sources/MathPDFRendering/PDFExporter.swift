import AppKit
import MathPDFCore
import MathPDFLaTeX
import PDFKit

/// Writes a copy of a PDF with mathpdf's annotations in it, for other apps.
/// The original's pages, links and annotations are kept as they are; ours are
/// added as standard PDF annotations: highlights and underlines (one per item,
/// however many lines), sticky notes, and each LaTeX formula as a stamp that
/// carries its drawing, so other editors can show it and move it like an
/// image. The original file is never written to.
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

    static func annotatedPDF(
        original data: Data, annotations: [Annotation]
    ) throws(Failure) -> Data {
        guard
            let output = try annotatedDocument(
                original: data, annotations: annotations
            ).dataRepresentation()
        else { throw .couldntBuild }
        return output
    }

    private static func annotatedDocument(
        original data: Data, annotations: [Annotation]
    ) throws(Failure) -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw .unreadablePDF
        }
        guard !document.isLocked else { throw .locked }
        // PDFKit would leave them out without saying so
        guard annotations.isEmpty || document.allowsCommenting else {
            throw .commentingNotAllowed
        }
        for (pageIndex, mark) in marks(for: annotations, in: document) {
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
    /// takes seconds, so that happens off it.
    public static func export(
        original data: Data, annotations: [Annotation], to url: URL,
        originalURL: URL?
    ) async throws {
        if let originalURL, isSameFile(url, originalURL) {
            throw Failure.wouldReplaceOriginal
        }
        let job = DocumentToWrite(
            document: try annotatedDocument(
                original: data, annotations: annotations))
        try await Task.detached(priority: .userInitiated) {
            guard let output = job.document.dataRepresentation() else {
                throw Failure.couldntBuild
            }
            removeLeftoverTempFiles(for: url)
            try AtomicFile.write(output, to: url)
        }.value
    }

    // MARK: Building

    /// Our annotations as PDF annotations, by page. The lines of a highlight
    /// or underline become one annotation, and so do a note's underlines.
    static func marks(
        for annotations: [Annotation], in document: PDFDocument
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
            case let .textBox(text, fontSize):
                marks.append(
                    (
                        annotation.pageIndex,
                        AnnotationMarks.textBox(
                            annotation, text: text, fontSize: fontSize,
                            color: color)
                    ))
            case let .latex(source, fontSize, expanded):
                let formula = LaTeXAnnotation(
                    bounds: annotation.bounds, source: source,
                    expanded: expanded, fontSize: fontSize, color: color,
                    pageRotation: rotation(annotation.pageIndex))
                marks.append((annotation.pageIndex, formula))
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
