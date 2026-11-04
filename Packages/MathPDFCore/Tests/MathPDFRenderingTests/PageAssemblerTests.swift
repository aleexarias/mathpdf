import AppKit
import CoreText
import Foundation
import MathPDFCore
import PDFKit
import Testing

@testable import MathPDFRendering

/// The PDF written after pages are moved, deleted or pasted.
struct PageAssemblerTests {
    /// A PDF whose pages say `labels`, one each.
    static func makePDF(_ labels: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(
            consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for label in labels {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: label,
                    attributes: [.font: NSFont.systemFont(ofSize: 24)]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func labels(_ data: Data) -> [String] {
        guard let document = PDFDocument(data: data) else { return [] }
        return (0..<document.pageCount).map {
            document.page(at: $0)?.string?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? "?"
        }
    }

    @Test func pagesAreMovedDeletedAndPasted() throws {
        let original = Self.makePDF(["A0", "A1", "A2", "A3"])
        let pasted = Self.makePDF(["B0", "B1"])
        let arrangement = PageArrangement([
            .existing(2), .pasted(1), .existing(0), .existing(3),
        ])
        let result = try PageAssembler.arrange(
            original, as: arrangement, pasted: pasted)
        #expect(Self.labels(result) == ["A2", "B1", "A0", "A3"])

        let moved = try PageAssembler.arrange(
            original, as: .moving([0, 1], to: 4, pageCount: 4))
        #expect(Self.labels(moved) == ["A2", "A3", "A0", "A1"])
    }

    @Test func theOutlineAndOtherAppsAnnotationsAreKept() throws {
        let source = try #require(
            PDFDocument(data: Self.makePDF(["A0", "A1", "A2"])))
        let square = PDFAnnotation(
            bounds: CGRect(x: 50, y: 50, width: 40, height: 40),
            forType: .square, withProperties: nil)
        source.page(at: 2)?.addAnnotation(square)
        let outline = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter"
        chapter.destination = PDFDestination(
            page: try #require(source.page(at: 2)), at: .zero)
        outline.insertChild(chapter, at: 0)
        source.outlineRoot = outline
        let original = try #require(source.dataRepresentation())

        let result = try #require(
            PDFDocument(
                data: try PageAssembler.arrange(
                    original, as: .moving([2], to: 0, pageCount: 3))))
        #expect(result.page(at: 0)?.annotations.map(\.type) == ["Square"])
        let entry = try #require(result.outlineRoot?.child(at: 0))
        #expect(entry.label == "Chapter")
        #expect(entry.destination?.page.map(result.index(for:)) == 0)
    }

    @Test func copiedPagesAreAPDFOfTheirOwn() throws {
        let original = Self.makePDF(["A0", "A1", "A2"])
        let copied = try PageAssembler.extract([2, 0], from: original)
        #expect(Self.labels(copied) == ["A2", "A0"])
        #expect(Self.labels(original) == ["A0", "A1", "A2"])
    }

    static func protectedPDF(_ options: [PDFDocumentWriteOption: Any])
        throws -> Data
    {
        let document = try #require(
            PDFDocument(data: makePDF(["A0", "A1"])))
        return try #require(document.dataRepresentation(options: options))
    }

    /// Many papers are encrypted only to set permissions. Their pages can
    /// change, and the result is still protected.
    @Test func aProtectedPDFKeepsItsProtection() throws {
        let original = try Self.protectedPDF([.ownerPasswordOption: "owner"])
        let result = try PageAssembler.arrange(
            original, as: .deleting([0], pageCount: 2))
        let document = try #require(PDFDocument(data: result))
        #expect(document.isEncrypted)
        #expect(Self.labels(result) == ["A1"])
    }

    @Test func aPDFsOwnSettingsCanForbidIt() throws {
        let restricted = try Self.protectedPDF([
            .ownerPasswordOption: "owner",
            .accessPermissionsOption:
                PDFAccessPermissions.allowsLowQualityPrinting.rawValue,
        ])
        let locked = try Self.protectedPDF([
            .ownerPasswordOption: "owner", .userPasswordOption: "user",
        ])
        for original in [restricted, locked] {
            #expect(throws: PageAssembler.Failure.protected) {
                try PageAssembler.arrange(
                    original, as: .deleting([0], pageCount: 2))
            }
            #expect(throws: PageAssembler.Failure.protected) {
                try PageAssembler.extract([0], from: original)
            }
        }
    }

    @Test func aBadArrangementIsRefused() {
        let original = Self.makePDF(["A0"])
        #expect(throws: PageAssembler.Failure.couldntBuild) {
            try PageAssembler.arrange(
                original, as: PageArrangement([.existing(3)]))
        }
        #expect(throws: PageAssembler.Failure.couldntBuild) {
            try PageAssembler.arrange(
                original, as: PageArrangement([.existing(0), .pasted(0)]))
        }
    }
}
