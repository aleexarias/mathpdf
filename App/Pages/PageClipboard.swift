import AppKit
import MathPDFCore
import PDFKit

/// Copied pages: a PDF of them, and their annotations numbered by page.
struct CopiedPages: Sendable {
    let pdf: Data
    let pageCount: Int
    let annotations: [Annotation]
}

extension NSPasteboard.PasteboardType {
    /// The annotations of copied pages, beside the pages as a PDF.
    static let pageAnnotations = Self("dev.mathpdf.page-annotations")
    static let draggedPages = Self("dev.mathpdf.dragged-pages")
}

/// Pages on the clipboard. Other apps get them as a PDF.
enum PageClipboard {
    static func write(
        _ pages: CopiedPages, to pasteboard: NSPasteboard = .general
    ) {
        let item = NSPasteboardItem()
        item.setData(pages.pdf, forType: .pdf)
        if let annotations = try? CopiedAnnotations.encode(
            pages.annotations, pageCount: pages.pageCount)
        {
            item.setData(annotations, forType: .pageAnnotations)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Pages copied in mathpdf, or with `fromOtherApps`, any PDF.
    static func hasPages(
        in pasteboard: NSPasteboard = .general, fromOtherApps: Bool
    ) -> Bool {
        let types: [NSPasteboard.PasteboardType] =
            fromOtherApps ? [.pageAnnotations, .pdf] : [.pageAnnotations]
        return pasteboard.availableType(from: types) != nil
    }

    static func read(
        from pasteboard: NSPasteboard = .general, fromOtherApps: Bool
    ) -> CopiedPages? {
        guard hasPages(in: pasteboard, fromOtherApps: fromOtherApps),
            let pdf = pasteboard.data(forType: .pdf),
            let pageCount = PDFDocument(data: pdf)?.pageCount, pageCount > 0
        else { return nil }
        let copied = pasteboard.data(forType: .pageAnnotations).flatMap(
            CopiedAnnotations.decode)
        return CopiedPages(
            pdf: pdf, pageCount: pageCount,
            annotations: copied?.pageCount == pageCount
                ? copied?.annotations ?? [] : [])
    }
}

/// Pages dragged from a sidebar, as one item. Drags stay within mathpdf, so
/// they name the window they come from instead of carrying the pages; the
/// pages are copied from it on drop.
@MainActor
struct DraggedPages {
    let session: DocumentSession
    let pages: [Int]

    private struct Item: Codable {
        let session: UUID
        let hash: String
        let pages: [Int]
    }

    static func makeItem(pages: [Int], of session: DocumentSession)
        -> NSPasteboardItem?
    {
        guard session.canCopyPages, !pages.isEmpty,
            let hash = session.annotationSet?.documentHash,
            let data = try? JSONEncoder().encode(
                Item(session: session.id, hash: hash, pages: pages))
        else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .draggedPages)
        return item
    }

    /// Nil unless the pages come from a window that's still as it was.
    init?(from pasteboard: NSPasteboard) {
        guard let data = pasteboard.data(forType: .draggedPages),
            let item = try? JSONDecoder().decode(Item.self, from: data),
            let session = OpenDocuments.shared.session(item.session),
            session.annotationSet?.documentHash == item.hash
        else { return nil }
        self.session = session
        pages = item.pages
    }
}
