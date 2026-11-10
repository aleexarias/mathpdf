import Testing

@testable import MathPDFLaTeX

/// Formulas between `$` signs in a text box's text.
struct InlineMathTests {
    @Test(
        arguments: [
            ("a $x^2$ b", [.text("a "), .math("x^2"), .text(" b")]),
            ("$a$$b$", [.math("a"), .math("b")]),
            (#"costs \$5"#, [.text("costs $5")]),
            (#"$\$$"#, [.math(#"\$"#)]),
            ("one $ two", [.text("one $ two")]),
            ("empty $$ stays", [.text("empty $$ stays")]),
            ("a $x\ny$ b", [.text("a $x\ny$ b")]),
            ("no math", [.text("no math")]),
            ("", []),
        ] as [(String, [InlineMath.Piece])])
    func piecesOf(_ text: String, are expected: [InlineMath.Piece]) {
        #expect(InlineMath.pieces(of: text) == expected)
    }

    @Test func onlyAClosedPairIsMath() {
        #expect(InlineMath.containsMath("so $x$"))
        #expect(!InlineMath.containsMath("so $x"))
        #expect(!InlineMath.containsMath(#"\$x\$"#))
    }

    @Test func mappingChangesOnlyTheFormulas() {
        let mapped = InlineMath.mappingMath(#"In $\R$, \$1 and $y$"#) {
            "[\($0)]"
        }
        #expect(mapped == #"In $[\R]$, \$1 and $[y]$"#)
    }
}
