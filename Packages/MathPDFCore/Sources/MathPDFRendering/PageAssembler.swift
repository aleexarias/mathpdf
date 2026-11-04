import Foundation
import MathPDFCore
import PDFKit

/// Builds the bytes of a PDF whose pages were moved, deleted or pasted, and of
/// copied pages. It always starts from a PDF's bytes, never from a document on
/// screen, whose pages carry mathpdf's own annotations.
public enum PageAssembler {
    public enum Failure: LocalizedError, Equatable {
        case unreadablePDF
        case protected
        case couldntBuild

        public var errorDescription: String? {
            switch self {
            case .unreadablePDF: "The PDF couldn't be read."
            case .protected:
                "The PDF's security settings don't allow it."
            case .couldntBuild: "The new PDF couldn't be put together."
            }
        }
    }

    /// A protected PDF keeps its encryption and restrictions when PDFKit
    /// writes it again, so only its own settings decide.
    public static func canChangePages(of document: PDFDocument) -> Bool {
        !document.isLocked && document.allowsDocumentAssembly
    }

    /// Copied pages become a PDF without the original's protection.
    public static func canCopyPages(of document: PDFDocument) -> Bool {
        canChangePages(of: document) && document.allowsCopying
    }

    /// `original` with its pages in the order `arrangement` gives, taking
    /// pasted pages from `pasted`. The rest of the file, such as its outline
    /// and other apps' annotations, is kept.
    public static func arrange(
        _ original: Data, as arrangement: PageArrangement,
        pasted: Data? = nil
    ) throws(Failure) -> Data {
        let document = try open(original, if: canChangePages)
        let source = try pasted.map { data throws(Failure) in
            try open(data, if: canCopyPages)
        }
        let pages = (0..<document.pageCount).compactMap(document.page(at:))
        var kept = Set<Int>()
        for case .existing(let index) in arrangement.pages {
            guard pages.indices.contains(index) else { throw .couldntBuild }
            kept.insert(index)
        }
        for index in pages.indices.reversed() where !kept.contains(index) {
            document.removePage(at: index)
        }
        // Everything before `position` is final; the page that belongs there
        // is either pasted in or swapped forward from further on.
        for (position, page) in arrangement.pages.enumerated() {
            switch page {
            case .existing(let index):
                let current = document.index(for: pages[index])
                if current != position {
                    document.exchangePage(at: position, withPageAt: current)
                }
            case .pasted(let index):
                guard let page = source?.page(at: index) else {
                    throw .couldntBuild
                }
                document.insert(page, at: position)
            }
        }
        guard document.pageCount == arrangement.pages.count,
            let data = document.dataRepresentation()
        else { throw .couldntBuild }
        return data
    }

    /// `pages` of `original`, in that order, as a PDF of their own.
    public static func extract(_ pages: [Int], from original: Data)
        throws(Failure) -> Data
    {
        let document = try open(original, if: canCopyPages)
        let copy = PDFDocument()
        for (position, index) in pages.enumerated() {
            guard let page = document.page(at: index) else {
                throw .couldntBuild
            }
            copy.insert(page, at: position)
        }
        guard let data = copy.dataRepresentation() else {
            throw .couldntBuild
        }
        return data
    }

    private static func open(
        _ data: Data, if allowed: (PDFDocument) -> Bool
    ) throws(Failure) -> PDFDocument {
        guard let document = PDFDocument(data: data) else {
            throw .unreadablePDF
        }
        guard allowed(document) else { throw .protected }
        return document
    }
}
