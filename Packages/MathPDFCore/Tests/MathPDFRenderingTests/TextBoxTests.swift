import AppKit
import MathPDFCore
import MathPDFLaTeX
import PDFKit
import Testing

@testable import MathPDFRendering

/// Text boxes are sized to their text: nothing may be cut off, whatever the
/// size or lines.
@MainActor
struct TextBoxTests {
    @Test(arguments: [
        "Hello, world", "Two lines\nwith descenders: gjpqy",
        "A much wider first line of text\nx\nthird",
        #"Area $\pi r^2$ and $\frac{a}{b}$"#,
        #"$\sum_{n=1}^\infty \frac{1}{n^2}$\nthen text"#,
    ])
    func theBoxFitsItsText(_ text: String) {
        for fontSize in [9.0, 14, 24, 40] {
            let fitted = TextBoxStyle.size(of: text, fontSize: fontSize)
            let roomy = CGSize(
                width: fitted.width + 100, height: fitted.height + 100)
            let shown = ink(
                text, fontSize: fontSize, box: fitted, canvas: roomy)
            let all = ink(text, fontSize: fontSize, box: roomy, canvas: roomy)
            #expect(
                shown == all,
                "\(fontSize) pt: \(shown) of \(all) dark pixels shown")
        }
    }

    /// At a set width the text wraps, and the height must hold every wrapped
    /// line, the way PDFKit wraps them.
    @Test(arguments: [60.0, 95, 140, 230])
    func wrappedTextFitsItsHeight(_ width: Double) {
        let text =
            """
            The Itô integral of a bounded adapted process is a martingale, \
            which is why the expectation vanishes.\nSecond paragraph.
            """
        for fontSize in [9.0, 14, 24] {
            let fitted = TextBoxStyle.size(
                of: text, fontSize: fontSize, width: width)
            #expect(Double(fitted.width) == width)
            let tall = CGSize(width: width, height: fitted.height + 300)
            let canvas = CGSize(width: width + 50, height: tall.height + 50)
            let shown = ink(
                text, fontSize: fontSize, box: fitted, canvas: canvas)
            let all = ink(text, fontSize: fontSize, box: tall, canvas: canvas)
            #expect(
                shown == all,
                """
                \(fontSize) pt at \(width) wide: \(shown) of \(all) dark \
                pixels shown
                """
            )
        }
    }

    /// And it holds them snugly: a box one line shorter cuts text off.
    @Test(arguments: [100.0, 200, 320])
    func wrappedTextHasNoSpareLines(_ width: Double) {
        let text =
            """
            The Itô integral of a bounded adapted process is a martingale, \
            which is why the expectation vanishes.
            """
        for fontSize in [12.0, 18] {
            let fitted = TextBoxStyle.size(
                of: text, fontSize: fontSize, width: width)
            let lineSpacing =
                TextBoxStyle.font(ofSize: fontSize).ascender
                - TextBoxStyle.font(ofSize: fontSize).descender + 1
            let shorter = CGSize(
                width: width, height: fitted.height - lineSpacing)
            let canvas = CGSize(width: width + 50, height: fitted.height + 50)
            #expect(
                ink(text, fontSize: fontSize, box: shorter, canvas: canvas)
                    < ink(
                        text, fontSize: fontSize, box: fitted, canvas: canvas))
        }
    }

    @Test func longTextIsCappedThenWraps() {
        let text = String(repeating: "word ", count: 80)
        let capped = TextBoxStyle.size(of: text, fontSize: 14, maxWidth: 300)
        let line = TextBoxStyle.size(of: "word", fontSize: 14)
        #expect(capped.width == 300)
        #expect(capped.height > 3 * line.height)  // several lines
        #expect(
            TextBoxStyle.size(of: "short", fontSize: 14, maxWidth: 300).width
                < 300)  // short text isn't stretched
    }

    // MARK: Formulas

    private static let formulas =
        #"""
        Since $\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}$, the \
        series converges, and $x^2$ is small.
        """#

    @Test func noBoxIsNarrowerThanItsWidestFormula() throws {
        let formula = #"\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}"#
        guard
            case .formula(let typeset) = LaTeXRenderer.typeset(
                formula, fontSize: 14, color: .black, style: .inline)
        else { throw TypesetFailed() }
        #expect(
            TextBoxLayout(Self.formulas, fontSize: 14).minimumWidth
                >= typeset.size.width + 2 * TextBoxStyle.inset)
        #expect(
            TextBoxLayout("plain words", fontSize: 14).minimumWidth
                == TextBoxLayout("", fontSize: 14).minimumWidth)
    }

    /// From the narrowest a box can be, everything is inside it: formulas
    /// whole, and every wrapped line.
    @Test(arguments: [0.0, 40, 150])
    func wrappedFormulasFitTheBox(_ extra: Double) {
        for fontSize in [10.0, 18] {
            let width =
                TextBoxLayout(Self.formulas, fontSize: fontSize).minimumWidth
                + extra
            let fitted = TextBoxStyle.size(
                of: Self.formulas, fontSize: fontSize, width: width)
            #expect(Double(fitted.width) == Double(width))
            let tall = CGSize(width: width, height: fitted.height + 300)
            let wide = CGSize(width: width + 300, height: tall.height + 50)
            let all = ink(
                Self.formulas, fontSize: fontSize, box: tall, canvas: wide)
            let inside = ink(
                Self.formulas, fontSize: fontSize, box: fitted,
                canvas: CGSize(width: width, height: tall.height + 50))
            #expect(
                inside == all,
                "\(fontSize) pt at \(width) wide: \(inside) of \(all) shown")
        }
    }

    @Test func aTallFormulaMakesItsLineTaller() {
        let plain = TextBoxStyle.size(of: "x y", fontSize: 14)
        let tall = TextBoxStyle.size(
            of: #"x $\frac{a}{b}$"#, fontSize: 14)
        #expect(tall.height > plain.height + 4)
    }

    @Test func aFormulaThatCantBeTypesetShowsItsSource() {
        let text = #"see $\notacommand{x}$"#
        let size = TextBoxStyle.size(of: text, fontSize: 14)
        #expect(
            size.width > TextBoxStyle.size(of: "see", fontSize: 14).width + 40)
    }

    @Test func onlyTextWithFormulasIsDrawnByUs() {
        func mark(_ text: String) -> PDFAnnotation {
            AnnotationMarks.textBox(
                Annotation(
                    kind: .textBox(text: text, fontSize: 14), pageIndex: 0,
                    bounds: CGRect(x: 0, y: 0, width: 200, height: 40),
                    color: RGBAColor(red: 0, green: 0, blue: 0)),
                text: text, fontSize: 14, expanded: nil, color: .black,
                pageRotation: 0)
        }
        #expect(mark("costs $5").type == "FreeText")
        let drawn = mark(#"area $\pi r^2$"#)
        #expect(drawn is MathTextAnnotation)
        #expect(drawn.contents == #"area $\pi r^2$"#)
    }

    @Test func emptyTextStillGetsAClickableBox() {
        let size = TextBoxStyle.size(of: "", fontSize: 14)
        #expect(size.width > 6 && size.height > 14)
    }

    private struct TypesetFailed: Error {}

    /// Dark pixels when a text box of size `box` is drawn at the top left of
    /// `canvas`, at 2×.
    private func ink(
        _ text: String, fontSize: Double, box: CGSize, canvas: CGSize
    ) -> Int {
        let scale: CGFloat = 2
        let width = Int(canvas.width * scale),
            height = Int(canvas.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let record = Annotation(
            kind: .textBox(text: text, fontSize: fontSize), pageIndex: 0,
            bounds: CGRect(
                origin: CGPoint(x: 0, y: canvas.height - box.height), size: box
            ),
            color: RGBAColor(red: 0, green: 0, blue: 0))
        let mark = AnnotationMarks.textBox(
            record, text: text, fontSize: fontSize, expanded: nil,
            color: .black, pageRotation: 0)
        mark.draw(with: .mediaBox, in: context)
        let bytes = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4)
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) {
            $0 + (bytes[$1] < 128 ? 1 : 0)
        }
    }
}
