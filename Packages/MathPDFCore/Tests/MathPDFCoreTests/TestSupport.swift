import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

let testHash = String(repeating: "ab", count: 32)

/// Every save is flushed to the drive, so suites that save a lot slow each
/// other's saves when run in parallel, and the autosave timing tests measure
/// saves. The suites nested in this one run one test at a time.
@Suite(.serialized) enum DiskHeavyTests {}

private let testFilesRoot = FileManager.default.temporaryDirectory.appending(
    path: "mathpdf-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

/// Removes them once the tests are done. A test can't, as a test's store can
/// still be writing when it ends.
private let removesTestFiles: Void = {
    atexit { try? FileManager.default.removeItem(at: testFilesRoot) }
    return ()
}()

func makeTemporaryRoot() -> URL {
    _ = removesTestFiles
    let url = testFilesRoot.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true)
    return url
}

func makeSet(
    hash: String = testHash, revision: Int, annotations: [Annotation] = []
) -> AnnotationSet {
    AnnotationSet(
        documentHash: hash, fileNameHint: "paper.pdf",
        pathHint: "/Users/me/Papers/paper.pdf",
        pageCount: 12, revision: revision, annotations: annotations)
}

/// Thrown by the crash hook to stand in for the process being killed.
struct SimulatedCrash: Error {}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Timestamp.parse("2026-11-03T12:00:00.000Z")!) {
        current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

enum Samples {
    static let created = Timestamp.parse("2026-11-03T11:44:02.317Z")!
    static let yellow = RGBAColor(
        red: 1, green: 0.839, blue: 0.039, alpha: 0.5)

    static let trickyLaTeX = [
        #"\int_0^T \sigma_t\,dW_t"#,
        #"\frac{\partial V}{\partial t} + \tfrac12 \sigma^2 S^2 "#
            + #"\frac{\partial^2 V}{\partial S^2} = rV"#,
        #"\text{"quotes", 'apostrophes', back\slash, % percent, "#
            + #"& amp, <tags>, /slash/}"#,
        "Unicode: é ü ß 漢字 עברית العربية 🧮👩🏽‍🔬 \u{0301}combining",
        "Control characters: tab\tnewline\nnull\u{0}line-separator\u{2028}end",
        ##"\\ \{ \} \$ \# \_ \^{} \~{}"##,
        "",
    ]

    static func underlineLines(page: Int = 0) -> [Annotation] {
        let group = UUID()
        return (0..<3).map { line in
            Annotation(
                kind: .underline, pageIndex: page,
                bounds: CGRect(
                    x: 72, y: 700.5 - Double(line) * 14.25, width: 468.125,
                    height: 12),
                color: RGBAColor(red: 1, green: 0.231, blue: 0.188),
                groupID: group, createdAt: created)
        }
    }

    static func highlight() -> Annotation {
        Annotation(
            kind: .highlight, pageIndex: 1,
            bounds: CGRect(x: 100.1, y: 500.2, width: 200.3, height: 14.4),
            color: yellow, createdAt: created, modifiedAt: created + 61.5)
    }

    static func pointNote(index: Int = 0) -> Annotation {
        Annotation(
            kind: .note(
                text: "Note #\(index): check Itô's lemma — §4.2",
                anchorRects: []), pageIndex: index % 12,
            bounds: CGRect(x: 540, y: 720, width: 20, height: 20),
            color: yellow, createdAt: created)
    }

    static func selectionNote() -> Annotation {
        let lines = [
            CGRect(x: 72, y: 400, width: 468, height: 12),
            CGRect(x: 72, y: 386, width: 120, height: 12),
        ]
        return Annotation(
            kind: .note(
                text: "Multi-line\nnote with \"quotes\" and emoji 🧠",
                anchorRects: lines),
            pageIndex: 2,
            bounds: CGRect(x: 192, y: 386, width: 20, height: 20),
            color: yellow, createdAt: created)
    }

    static func latex(_ source: String = #"\int_0^T \sigma_t\,dW_t"#)
        -> Annotation
    {
        Annotation(
            kind: .latex(source: source, fontSize: 15.5), pageIndex: 3,
            bounds: CGRect(x: 90, y: 400, width: 160.75, height: 28.25),
            color: RGBAColor(red: 0, green: 0, blue: 0), createdAt: created)
    }

    static func textBox(_ text: String = "A text box\nover two lines")
        -> Annotation
    {
        Annotation(
            kind: .textBox(text: text, fontSize: 13.5), pageIndex: 4,
            bounds: CGRect(x: 300, y: 250, width: 120.25, height: 40.5),
            color: RGBAColor(red: 0.2, green: 0.3, blue: 0.9),
            createdAt: created)
    }

    static func mathTextBox() -> Annotation {
        Annotation(
            kind: .textBox(
                text: #"Since $\R^n$ costs \$1"#, fontSize: 14,
                expanded: #"Since $\mathbb{R}^n$ costs \$1"#),
            pageIndex: 0,
            bounds: CGRect(x: 72, y: 500, width: 150.5, height: 30.25),
            color: RGBAColor(red: 0, green: 0, blue: 0), createdAt: created)
    }

    static func everyKind() -> [Annotation] {
        underlineLines() + [highlight(), pointNote(), selectionNote()]
            + trickyLaTeX.map(latex) + trickyLaTeX.map(textBox)
            + [mathTextBox()]
    }
}

func tempFiles(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.contains(AtomicFile.tempMarker) }
}

func fixtureData(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}
