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
        case wouldReplaceOriginal
        case couldntBuild

        public var errorDescription: String? {
            switch self {
            case .unreadablePDF: "The PDF couldn't be read."
            case .locked:
                "The PDF is password-protected, so a copy can't be written."
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

    public static func annotatedPDF(
        original data: Data, annotations: [Annotation]
    ) throws(Failure) -> Data {
        guard let document = PDFDocument(data: data) else {
            throw .unreadablePDF
        }
        guard !document.isLocked else { throw .locked }
        for (pageIndex, mark) in marks(for: annotations) {
            document.page(at: pageIndex)?.addAnnotation(mark)
        }
        guard let output = document.dataRepresentation() else {
            throw .couldntBuild
        }
        return output
    }

    /// Writes the annotated copy to `url` in one step: whatever was there
    /// before stays until the new file is complete. Never to `original`.
    public static func export(
        original data: Data, annotations: [Annotation], to url: URL,
        originalURL: URL?
    ) throws {
        if let originalURL, isSameFile(url, originalURL) {
            throw Failure.wouldReplaceOriginal
        }
        let output = try annotatedPDF(original: data, annotations: annotations)
        removeLeftoverTempFiles(for: url)
        try AtomicFile.write(output, to: url)
    }

    // MARK: Building

    /// Our annotations as PDF annotations, by page. The lines of a highlight
    /// or underline become one annotation, and so do a note's underlines.
    static func marks(for annotations: [Annotation]) -> [(
        pageIndex: Int, mark: PDFAnnotation
    )] {
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
                                type, lines.map(\.bounds), color)
                        ))
                }
            case let .note(text, anchors):
                if !anchors.isEmpty {
                    marks.append(
                        (
                            annotation.pageIndex,
                            AnnotationMarks.markup(
                                .underline, anchors,
                                AnnotationMarks.anchorColor(for: color))
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
            case let .latex(source, fontSize):
                let formula = LaTeXAnnotation(
                    bounds: annotation.bounds, source: source,
                    fontSize: fontSize, color: color)
                marks.append((annotation.pageIndex, formula))
            }
        }
        return marks
    }

    // MARK: Files

    /// Whether two URLs name the same file, however they're spelled.
    public nonisolated static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath()
            == b.standardizedFileURL.resolvingSymlinksInPath()
        {
            return true
        }
        // Different spellings of one file (e.g. case on a case-insensitive
        // disk): same file ID.
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
