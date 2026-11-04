import AppKit
import CoreText
import Foundation
import MathPDFCore
import PDFKit
import Testing

@testable import MathPDFRendering

/// The exported copy, as other apps will see it.
@MainActor
struct ExportTests {
    let yellow = RGBAColor(red: 1, green: 0.88, blue: 0.32)
    let red = RGBAColor(red: 1, green: 0.48, blue: 0.45)
    let noteYellow = RGBAColor(red: 1, green: 0.95, blue: 0.62)
    let black = RGBAColor(red: 0, green: 0, blue: 0)

    @Test func annotationsBecomeStandardPDFAnnotations() throws {
        let group = UUID()
        let examSize = TextBoxStyle.size(of: "Exam question", fontSize: 14)
        let annotations = [
            Annotation(
                kind: .highlight, pageIndex: 0,
                bounds: CGRect(x: 72, y: 700, width: 300, height: 14),
                color: yellow, groupID: group),
            Annotation(
                kind: .highlight, pageIndex: 0,
                bounds: CGRect(x: 72, y: 684, width: 180, height: 14),
                color: yellow, groupID: group),
            Annotation(
                kind: .underline, pageIndex: 1,
                bounds: CGRect(x: 72, y: 500, width: 200, height: 14),
                color: red),
            Annotation(
                kind: .note(
                    text: "Check this step",
                    anchorRects: [
                        CGRect(x: 72, y: 600, width: 100, height: 14),
                        CGRect(x: 72, y: 584, width: 60, height: 14),
                    ]),
                pageIndex: 0,
                bounds: CGRect(x: 135, y: 584, width: 15, height: 15),
                color: noteYellow),
            Annotation(
                kind: .latex(
                    source: #"\int_0^1 x\,dx = \frac{1}{2}"#, fontSize: 16),
                pageIndex: 2,
                bounds: CGRect(x: 300, y: 400, width: 90, height: 34),
                color: black),
            Annotation(
                kind: .textBox(text: "Exam question", fontSize: 14),
                pageIndex: 1,
                bounds: CGRect(
                    origin: CGPoint(x: 72, y: 300),
                    size: examSize),
                color: red),
        ]
        let original = Self.makePDF(pages: 3)
        let exported = try PDFExporter.annotatedPDF(
            original: original, annotations: annotations)
        let document = try #require(PDFDocument(data: exported))
        #expect(document.pageCount == 3)
        for index in 0..<3 {  // the pages themselves are unchanged
            #expect(
                document.page(at: index)?.string
                    == PDFDocument(data: original)?.page(at: index)?.string)
        }

        let first = try #require(document.page(at: 0)).annotations
        let highlights = first.filter { $0.type == "Highlight" }
        // the two lines are one highlight, as PDF editors make them
        #expect(highlights.count == 1)
        #expect(highlights.first?.quadrilateralPoints?.count == 8)
        #expect(
            highlights.first.map {
                $0.bounds.contains(
                    CGRect(x: 72, y: 684, width: 300, height: 30).insetBy(
                        dx: 1, dy: 1))
            } == true)
        let note = try #require(first.first { $0.type == "Text" })
        #expect(note.contents == "Check this step")
        // the note's two lines, as one underline
        #expect(first.filter { $0.type == "Underline" }.count == 1)
        let second = try #require(document.page(at: 1)).annotations
        #expect(second.map(\.type) == ["Underline", "FreeText"])
        // real text, editable in other apps
        #expect(second.last?.contents == "Exam question")
        #expect(second.last?.font?.pointSize == 14)

        let stamp = try #require(document.page(at: 2)?.annotations.first)
        #expect(stamp.type == "Stamp")
        #expect(stamp.contents == #"\int_0^1 x\,dx = \frac{1}{2}"#)
        // its drawing travels with it
        #expect(String(decoding: exported, as: UTF8.self).contains("/AP"))
    }

    @Test func theOriginalsOwnAnnotationsAreKept() throws {
        let source = try #require(PDFDocument(data: Self.makePDF(pages: 1)))
        let square = PDFAnnotation(
            bounds: CGRect(x: 50, y: 50, width: 40, height: 40),
            forType: .square, withProperties: nil)
        source.page(at: 0)?.addAnnotation(square)
        let original = try #require(source.dataRepresentation())
        let exported = try PDFExporter.annotatedPDF(
            original: original,
            annotations: [
                Annotation(
                    kind: .underline, pageIndex: 0,
                    bounds: CGRect(x: 72, y: 500, width: 100, height: 14),
                    color: red)
            ])
        let types = try #require(PDFDocument(data: exported)?.page(at: 0))
            .annotations.compactMap(\.type)
        #expect(Set(types) == ["Square", "Underline"])
    }

    @Test func neverWritesTheOriginal() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalURL = folder.appending(path: "lecture.pdf")
        let original = Self.makePDF(pages: 1)
        try original.write(to: originalURL)
        let notes = [
            Annotation(
                kind: .underline, pageIndex: 0,
                bounds: CGRect(x: 72, y: 500, width: 100, height: 14),
                color: red)
        ]

        for spelling in [
            originalURL, folder.appending(path: "sub/../lecture.pdf"),
            URL(filePath: originalURL.path + "/../lecture.pdf"),
        ] {
            #expect(throws: PDFExporter.Failure.wouldReplaceOriginal) {
                try PDFExporter.export(
                    original: original, annotations: notes, to: spelling,
                    originalURL: originalURL)
            }
        }
        #expect(try Data(contentsOf: originalURL) == original)
    }

    @Test func aNewExportReplacesTheLastOneInOneStep() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalURL = folder.appending(path: "lecture.pdf")
        let original = Self.makePDF(pages: 1)
        try original.write(to: originalURL)
        let target = PDFExporter.quickExportURL(for: originalURL)
        // A temp file from an export a crash interrupted.
        try Data("half".utf8).write(
            to: folder.appending(
                path:
                    ".\(target.lastPathComponent)\(AtomicFile.tempMarker)DEAD")
        )

        let one = [
            Annotation(
                kind: .underline, pageIndex: 0,
                bounds: CGRect(x: 72, y: 500, width: 100, height: 14),
                color: red)
        ]
        try PDFExporter.export(
            original: original, annotations: one, to: target,
            originalURL: originalURL)
        let two =
            one + [
                Annotation(
                    kind: .highlight, pageIndex: 0,
                    bounds: CGRect(x: 72, y: 600, width: 100, height: 14),
                    color: yellow)
            ]
        try PDFExporter.export(
            original: original, annotations: two, to: target,
            originalURL: originalURL)

        let types = try #require(PDFDocument(url: target)?.page(at: 0))
            .annotations.compactMap(\.type)
        #expect(Set(types) == ["Underline", "Highlight"])
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .sorted() == ["lecture.pdf", "lecture_annotated.pdf"])
        #expect(try Data(contentsOf: originalURL) == original)
    }

    @Test func passwordProtectedPDFsAreRefused() throws {
        let document = try #require(PDFDocument(data: Self.makePDF(pages: 1)))
        let locked = try #require(
            document.dataRepresentation(options: [
                PDFDocumentWriteOption.userPasswordOption: "secret",
                PDFDocumentWriteOption.ownerPasswordOption: "owner",
            ]))
        #expect(throws: PDFExporter.Failure.locked) {
            try PDFExporter.annotatedPDF(original: locked, annotations: [])
        }
        #expect(throws: PDFExporter.Failure.unreadablePDF) {
            try PDFExporter.annotatedPDF(
                original: Data("not a pdf".utf8), annotations: [])
        }
    }

    @Test(arguments: [
        (
            "/Users/a/Lectures/week 3.pdf",
            "/Users/a/Lectures/week 3_annotated.pdf"
        ),
        ("/Users/a/Notes.PDF", "/Users/a/Notes_annotated.pdf"),
        ("/Users/a/x_annotated.pdf", "/Users/a/x_annotated_annotated.pdf"),
    ])
    func quickExportGoesNextToTheOriginal(original: String, expected: String) {
        #expect(
            PDFExporter.quickExportURL(for: URL(filePath: original)).path
                == expected)
    }

    // MARK: Helpers

    /// A PDF with a line of text on each page, so page contents can be
    /// compared.
    static func makePDF(pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(
            consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "Page \(page): the Ito integral is a martingale.",
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "mathpdf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }
}
