import AppKit
import Testing

@testable import MathPDFLaTeX

/// Formulas that took the whole app down inside SwiftMath, where no error can
/// be caught. A crash here stops the whole test run.
@MainActor
struct SwiftMathCrashTests {
    private func result(_ source: String) -> LaTeXRenderer.Result {
        LaTeXRenderer.typeset(source, fontSize: 16, color: .black)
    }

    private func isFormula(_ source: String) -> Bool {
        if case .formula = result(source) { return true }
        return false
    }

    private func message(_ source: String) -> String? {
        if case .invalid(let message) = result(source) { return message }
        return nil
    }

    @Test(arguments: [
        #"x\textcolor{#ff0000}{\frac{1}{2}}"#,
        #"x\textcolor{#ff0000}{\sqrt{2}}"#,
        #"x\textcolor{#ff0000}{\sum_i}"#,
        #"x\textcolor{#ff0000}{\left(a\right)}"#,
        #"x\textcolor{#ff0000}{}"#,
        #"x\textcolor{#ff0000}{ \, \frac{1}{2}}"#,
        #"x\textcolor{#ff0000}{\textcolor{#00ff00}{\frac{1}{2}}}"#,
        #"\frac{x\textcolor{#ff0000}{\frac{1}{2}}}{y}"#,
        #"\textcolor{#ff0000}{\frac{1}{2}}\textcolor{#00ff00}{\sqrt{2}}"#,
    ])
    func aColoredGroupCanStartWithAnything(_ source: String) {
        #expect(isFormula(source))
    }

    /// The repair mustn't cost the group its color.
    @Test func aRepairedGroupStaysColored() throws {
        let source = #"x\textcolor{#ff0000}{\frac{1}{2}}"#
        guard case .formula(let typeset) = result(source) else {
            Issue.record("didn't typeset")
            return
        }
        let width = Int(ceil(typeset.size.width))
        let height = Int(ceil(typeset.size.height))
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        LaTeXRenderer.draw(typeset.display, in: context)
        let bytes = try #require(context.data).assumingMemoryBound(
            to: UInt8.self)
        let colors = (0..<width * height).map { pixel in
            (bytes[pixel * 4], bytes[pixel * 4 + 1], bytes[pixel * 4 + 3])
        }
        #expect(colors.contains { $0.0 > 150 && $0.1 < 60 && $0.2 > 150 })
        #expect(colors.contains { $0.0 < 60 && $0.1 < 60 && $0.2 > 150 })
    }

    @Test(arguments: [
        #"\operatorname{}"#, #"\operatorname{ }"#, #"\operatorname*{}"#,
        #"\operatorname\,"#, #"\operatorname\!"#, #"\operatorname\ "#,
        #"\operatorname\;"#, #"x\operatorname{\!}y"#,
    ])
    func anOperatorNeedsAName(_ source: String) {
        #expect(message(source) == #"\operatorname needs a name."#)
    }

    private static let tooDeep = "This formula is nested too deeply."

    private nonisolated static func nesting(_ depth: Int) -> [String] {
        [
            String(repeating: "{", count: depth) + "x"
                + String(repeating: "}", count: depth),
            String(repeating: "{", count: depth),
            String(repeating: #"\frac{"#, count: depth) + "x"
                + String(repeating: "}{y}", count: depth),
            String(repeating: "x^{", count: depth) + "x"
                + String(repeating: "}", count: depth),
            String(repeating: "x_{", count: depth) + "x"
                + String(repeating: "}", count: depth),
            String(repeating: #"\left("#, count: depth) + "x"
                + String(repeating: #"\right)"#, count: depth),
            String(repeating: #"\begin{matrix}"#, count: depth) + "x"
                + String(repeating: #"\end{matrix}"#, count: depth),
            String(repeating: #"\textcolor{#ff0000}{"#, count: depth) + "x"
                + String(repeating: "}", count: depth),
            String(repeating: #"\sqrt["#, count: depth) + "x"
                + String(repeating: "]{y}", count: depth),
            String(repeating: #"\sqrt"#, count: depth) + " x",
            String(repeating: #"\sqrt "#, count: depth) + "x",
            String(repeating: #"\hat"#, count: depth) + " x",
            String(repeating: #"\frac"#, count: depth) + "12",
            String(repeating: #"x\over "#, count: depth) + "x",
            String(repeating: #"x\choose "#, count: depth) + "x",
            String(repeating: #"x\atop "#, count: depth) + "x",
        ]
    }

    @Test(arguments: nesting(20000) + nesting(101))
    func whatsNestedTooDeeplyIsRefused(_ source: String) {
        #expect(message(source) == Self.tooDeep)
    }

    /// The limit itself has to be safe, and quick enough for the main thread.
    @Test(arguments: nesting(99))
    func theDeepestAllowedDoesntCrash(_ source: String) {
        #expect(message(source) != Self.tooDeep)
    }

    /// Long isn't deep.
    @Test(arguments: [
        String(repeating: "x+", count: 5000) + "x",
        String(repeating: #"\frac{1}{2}+"#, count: 500) + "x",
        String(repeating: "{x}", count: 500),
        String(repeating: #"\alpha+"#, count: 500) + "x",
        String(repeating: #"\left(x\right)"#, count: 500),
        String(repeating: "{n\\choose k}+", count: 50) + "x",
        #"\begin{aligned}"# + String(repeating: #"a&=b\\"#, count: 300)
            + #"\end{aligned}"#,
    ])
    func whatsOnlyLongIsFine(_ source: String) {
        #expect(isFormula(source))
    }
}
