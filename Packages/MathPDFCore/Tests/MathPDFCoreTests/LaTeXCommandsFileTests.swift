import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

/// The file of the user's own commands, and what a formula keeps from them.
struct LaTeXCommandsFileTests {
    private let yellow = RGBAColor(red: 1, green: 0.9, blue: 0.3)

    @Test func nothingDefinedBeforeTheFirstSave() throws {
        let file = LaTeXCommandsFile(rootURL: makeTemporaryRoot())
        #expect(try file.read() == "")
    }

    @Test func whatsWrittenIsReadBack() throws {
        let root = makeTemporaryRoot().appending(path: "not yet there")
        let file = LaTeXCommandsFile(rootURL: root)
        let text = #"\newcommand{\é}{é} % ✓"# + "\n"
        try file.write(text)
        #expect(try file.read() == text)
        #expect(file.url.lastPathComponent == "latex-commands.tex")
    }

    /// Reading it as empty would let the next save overwrite it.
    @Test func aFileThatCantBeReadIsAnError() throws {
        let file = LaTeXCommandsFile(rootURL: makeTemporaryRoot())
        let damaged = Data([0xFF, 0xFE, 0x00, 0xC3])
        try damaged.write(to: file.url)
        #expect(throws: (any Error).self) { try file.read() }
        #expect(try Data(contentsOf: file.url) == damaged)
    }

    private func formula(_ kind: Annotation.Kind) -> Annotation {
        Annotation(
            kind: kind, pageIndex: 0,
            bounds: CGRect(x: 10, y: 100, width: 20, height: 20),
            color: yellow)
    }

    @Test func aFormulaKeepsWhatItExpandedTo() throws {
        let begun = formula(.latex(source: "", fontSize: 16))
        let edit = try #require(
            [begun].finishingLaTeX(
                begun.id, source: #"\R"#, expanded: #"\mathbb{R}"#,
                fontSize: 16, size: CGSize(width: 30, height: 20),
                isNew: true))
        #expect(
            edit.annotations[0].kind
                == .latex(
                    source: #"\R"#, fontSize: 16, expanded: #"\mathbb{R}"#))
    }

    @Test func nothingIsKeptWhenNoCommandWasUsed() throws {
        let begun = formula(.latex(source: "", fontSize: 16))
        let edit = try #require(
            [begun].finishingLaTeX(
                begun.id, source: "x", expanded: "x", fontSize: 16,
                size: CGSize(width: 30, height: 20), isNew: true))
        #expect(edit.annotations[0].kind == .latex(source: "x", fontSize: 16))
    }

    @Test(arguments: [
        (
            #"In $\R^n$"#, #"In $\mathbb{R}^n$"#,
            Optional(#"In $\mathbb{R}^n$"#)
        ),
        ("x", "x", nil),
    ])
    func aTextBoxKeepsWhatItsFormulasExpandedTo(
        text: String, expanded: String, kept: String?
    ) throws {
        let begun = formula(.textBox(text: "", fontSize: 14))
        let edit = try #require(
            [begun].finishingTextBox(
                begun.id, text: text, expanded: expanded, fontSize: 14,
                size: CGSize(width: 60, height: 20), isNew: true))
        #expect(
            edit.annotations[0].kind
                == .textBox(text: text, fontSize: 14, expanded: kept))
    }

    @Test func aFormulaLeftAloneIsNoEdit() {
        let entered = formula(
            .latex(source: #"\R"#, fontSize: 16, expanded: #"\mathbb{R}"#))
        #expect(
            [entered].finishingLaTeX(
                entered.id, source: #"\R"#, expanded: #"\mathbb{R}"#,
                fontSize: 16, size: .zero, isNew: false) == nil)
    }

    @Test func theExpansionIsStoredOnlyWhenThereIsOne() throws {
        let set = makeSet(
            revision: 1,
            annotations: [
                formula(
                    .latex(
                        source: #"\R"#, fontSize: 16, expanded: #"\mathbb{R}"#)
                ),
                formula(.latex(source: "x", fontSize: 16)),
                formula(
                    .textBox(
                        text: #"In $\R^n$"#, fontSize: 14,
                        expanded: #"In $\mathbb{R}^n$"#)),
                formula(.textBox(text: "Plain", fontSize: 14)),
            ])
        let data = try StoreFile.encode(set)
        #expect(try StoreFile.decode(data).set.annotations == set.annotations)
        let occurrences =
            String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\"expanded\"").count - 1
        #expect(occurrences == 2)
        #expect(
            try StoreFile.decode(data).schemaVersion
                == StoreFile.currentSchemaVersion)
    }
}
