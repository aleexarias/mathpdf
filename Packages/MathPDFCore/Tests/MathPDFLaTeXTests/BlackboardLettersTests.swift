import AppKit
import CoreText
import SwiftMath
import Testing

@testable import MathPDFLaTeX

/// `\mathbb` capitals in the AMS font, laid out with its widths.
@MainActor
struct BlackboardLettersTests {
    private struct Failure: Error {}

    private func typeset(_ source: String, size: CGFloat = 20) throws
        -> LaTeXRenderer.Typeset
    {
        guard
            case .formula(let typeset) = LaTeXRenderer.typeset(
                source, fontSize: size, color: .black)
        else { throw Failure() }
        return typeset
    }

    /// SwiftMath doesn't make this public.
    private func position(of display: MTDisplay) -> CGPoint {
        var mirror: Mirror? = Mirror(reflecting: display)
        while let current = mirror {
            for child in current.children where child.label == "position" {
                return child.value as? CGPoint ?? .zero
            }
            mirror = current.superclassMirror
        }
        return .zero
    }

    /// Every line of text in a display, with where it is on the page.
    private func lines(in display: MTDisplay, at origin: CGPoint = .zero)
        -> [(line: MTCTLineDisplay, x: CGFloat, y: CGFloat)]
    {
        let position = position(of: display)
        let x = origin.x + position.x
        let y = origin.y + position.y
        var found: [(line: MTCTLineDisplay, x: CGFloat, y: CGFloat)] = []
        if let line = display as? MTCTLineDisplay {
            found.append((line, x, y))
        }
        var mirror: Mirror? = Mirror(reflecting: display)
        while let current = mirror {
            for child in current.children {
                let parts =
                    (child.value as? MTDisplay).map { [$0] }
                    ?? (child.value as? [MTDisplay]) ?? []
                for part in parts {
                    found += lines(in: part, at: CGPoint(x: x, y: y))
                }
            }
            mirror = current.superclassMirror
        }
        return found
    }

    private func fontNames(of line: MTCTLineDisplay) -> [String] {
        (CTLineGetGlyphRuns(line.line) as! [CTRun]).map { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            return CTFontCopyPostScriptName(font) as String
        }
    }

    private func amsLines(_ source: String) throws -> Int {
        try lines(in: typeset(source).display).filter {
            fontNames(of: $0.line).contains { $0.contains("KaTeX_AMS") }
        }.count
    }

    private func width(_ line: MTCTLineDisplay) -> CGFloat {
        CTLineGetTypographicBounds(line.line, nil, nil, nil)
    }

    @Test(arguments: [
        #"\mathbb{R}"#, #"x\mathbb{R}y"#, #"\frac{\mathbb{R}}{2}"#,
        #"\frac{2}{\mathbb{R}}"#, #"\sqrt{\mathbb{R}}"#,
        #"\sqrt[\mathbb{R}]{2}"#, #"\hat{\mathbb{R}}"#,
        #"\overline{\mathbb{R}}"#, #"\underline{\mathbb{R}}"#,
        #"x^{\mathbb{R}}"#, #"x_{\mathbb{R}}"#, #"\sum_{\mathbb{R}}^{2}"#,
        #"\lim_{\mathbb{R}}"#, #"\left(\mathbb{R}\right)"#,
        #"\begin{matrix}\mathbb{R}\end{matrix}"#,
        #"\begin{cases}\mathbb{R} & x\end{cases}"#,
        #"\textcolor{#ff0000}{\mathbb{R}}"#, #"\color{#ff0000}{\mathbb{R}}"#,
    ])
    func aCapitalIsAMSWhereverItIs(_ source: String) throws {
        #expect(try amsLines(source) == 1)
    }

    @Test func everyCapitalInAGroupIsAMS() throws {
        #expect(try amsLines(#"\mathbb{RNZ}"#) == 3)
    }

    @Test(arguments: [#"\mathbb{k}"#, #"\mathbb{1}"#, #"x"#, #"\mathrm{R}"#])
    func nothingElseIs(_ source: String) throws {
        #expect(try amsLines(source) == 0)
    }

    /// `M` is the widest difference from Latin Modern, `J` the narrowest.
    @Test(arguments: ["M", "J", "R", "N"])
    func whatFollowsClearsTheLetter(_ letter: String) throws {
        let all = lines(in: try typeset(#"\mathbb{\#(letter)}x"#).display)
        let capital = try #require(
            all.first { $0.line.atoms.first?.nucleus != "𝑥" })
        let next = try #require(all.last)
        #expect(
            abs(next.x - (capital.x + width(capital.line))) < 0.01)
    }

    /// The width is reserved wherever the letter is, not only at the top.
    @Test(arguments: [
        #"\frac{\mathbb{M}x}{2}"#, #"\frac{2}{\mathbb{M}x}"#,
        #"\sqrt{\mathbb{M}x}"#, #"\sqrt[\mathbb{M}x]{2}"#,
        #"\hat{\mathbb{M}x}"#, #"\overline{\mathbb{M}x}"#,
        #"\underline{\mathbb{M}x}"#, #"y^{\mathbb{M}x}"#, #"y_{\mathbb{M}x}"#,
        #"\left(\mathbb{M}x\right)"#,
        #"\begin{matrix}\mathbb{M}x\end{matrix}"#,
        #"\textcolor{#ff0000}{\mathbb{M}x}"#,
    ])
    func whatFollowsClearsTheLetterInside(_ source: String) throws {
        let all = lines(in: try typeset(source).display)
        let capital = try #require(
            all.first { $0.line.atoms.first?.nucleus == "𝕄" })
        let next = try #require(
            all.first { $0.line.atoms.first?.nucleus == "𝑥" })
        #expect(
            abs(next.x - (capital.x + width(capital.line))) < 0.01)
    }

    /// Beside one that's changed, other capitals stay on one line with their
    /// neighbours, with no added space.
    @Test(arguments: [
        #"\mathbb{M}Rx"#, #"\mathbb{M}\mathrm{R}x"#,
        #"\mathbb{M}\mathcal{R}x"#,
    ])
    func otherCapitalsAreLeftAlone(_ source: String) throws {
        #expect(try lines(in: typeset(source).display).count == 2)
    }

    @Test func scriptsClearTheLetterAtTheUsualHeight() throws {
        let all = lines(in: try typeset(#"\mathbb{M}^n"#).display)
        let capital = try #require(all.first)
        let script = try #require(all.last)
        #expect(all.count >= 2)
        #expect(script.x >= capital.x + width(capital.line) - 0.01)

        let plain = lines(in: try typeset(#"\mathrm{M}^n"#).display)
        let plainRise = (plain.last?.y ?? 0) - (plain.first?.y ?? 0)
        #expect(abs((script.y - capital.y) - plainRise) < 0.01)
    }

    @Test func bothScriptsAreKept() throws {
        let all = lines(in: try typeset(#"\mathbb{R}_a^b"#).display)
        let nuclei = all.compactMap { $0.line.atoms.first?.nucleus }
        #expect(nuclei.contains("𝑎") && nuclei.contains("𝑏"))
    }

    /// In math units, at a size where 18 of them make 20 points: TeX puts 4
    /// around a binary operator and 5 around a relation.
    @Test(arguments: [
        (#"x+\mathbb{R}"#, 4.0), (#"\mathbb{R}+x"#, 4.0),
        (#"x=\mathbb{R}"#, 5.0), (#"\mathbb{R}=x"#, 5.0),
    ])
    func spacingAroundOperatorsIsTheUsual(source: String, units: CGFloat)
        throws
    {
        let all = try lines(in: typeset(source, size: 20).display)
        let first = try #require(all.first)
        let second = try #require(all.last)
        let gap = second.x - (first.x + width(first.line))
        #expect(abs(gap - units / 18 * 20) < 0.01)
    }

    @Test func colourAndSizeAreKept() throws {
        guard
            case .formula(let typeset) = LaTeXRenderer.typeset(
                #"\mathbb{R}"#, fontSize: 31, color: .red)
        else { throw Failure() }
        let line = try #require(lines(in: typeset.display).first).line
        let runs = CTLineGetGlyphRuns(line.line) as! [CTRun]
        let run = try #require(runs.first)
        let attributes = CTRunGetAttributes(run) as NSDictionary
        let font = attributes[kCTFontAttributeName] as! CTFont
        #expect(CTFontGetSize(font) == 31)
        #expect(attributes[kCTForegroundColorAttributeName] != nil)
    }

    @Test func badSourceIsStillReported() {
        guard
            case .invalid = LaTeXRenderer.typeset(
                #"\mathbb{R"#, fontSize: 16, color: .black)
        else {
            Issue.record("expected an error")
            return
        }
    }

    /// Its box was measured with narrower letters when it was saved.
    @Test func aFormulaSavedEarlierIsntClipped() throws {
        let typeset = try typeset(#"\mathbb{MWK}"#, size: 16)
        let saved = CGRect(
            x: 10, y: 10, width: typeset.size.width - 8,
            height: typeset.size.height)
        let annotation = LaTeXAnnotation(
            bounds: saved, source: #"\mathbb{MWK}"#, fontSize: 16,
            color: .black)
        #expect(annotation.bounds.width == typeset.size.width)
        #expect(annotation.bounds.origin == saved.origin)
        annotation.bounds = saved.offsetBy(dx: 30, dy: 0)
        #expect(annotation.bounds.width == typeset.size.width)
        #expect(annotation.bounds.minX == 40)
    }
}
