import AppKit
import PDFKit
import Testing

@testable import MathPDFLaTeX

/// How formulas come out: on the page, and in a PDF written for other apps.
@MainActor
struct RenderingTests {
    /// Fraction bars and the bars of roots are strokes, not glyphs; they need
    /// AppKit's context pointed at the drawing (see `LaTeXRenderer.draw`).
    @Test(arguments: [#"\frac{1}{2}"#, #"\sqrt{x+y}"#, #"\overline{ab}"#])
    func barsAreDrawn(_ source: String) throws {
        let formula = try annotation(source)
        let rows = darkPixelsPerRow(size: formula.bounds.size) {
            formula.draw(with: .mediaBox, in: $0)
        }
        let width = Int(formula.bounds.width * Self.scale)
        // A bar is one solid row across most of the formula; glyphs alone
        // never make one.
        #expect(rows.max()! > width / 2, "no bar in \(source)")
    }

    @Test func selectionTintOnlyWhenSelected() throws {
        let formula = try annotation(#"x"#)
        func tinted() -> Bool {
            let size = formula.bounds.size
            let all = pixels(size: size) {
                formula.draw(with: .mediaBox, in: $0)
            }
            // just inside the top-left corner, clear of the glyph
            let pixel = all[6 * Int(size.width * Self.scale) + 6]
            // any accent colour, even graphite
            return min(pixel.red, pixel.green, pixel.blue) < 250
        }
        #expect(!tinted())
        formula.isSelected = true
        #expect(tinted())
        formula.isSelected = false
        #expect(!tinted())
    }

    @Test func typesettingIsCached() throws {
        guard
            case .formula(let first) = LaTeXRenderer.typeset(
                #"\sum_{i=1}^n i"#, fontSize: 16, color: .black),
            case .formula(let second) = LaTeXRenderer.typeset(
                #"\sum_{i=1}^n i"#, fontSize: 16, color: .black),
            case .formula(let bigger) = LaTeXRenderer.typeset(
                #"\sum_{i=1}^n i"#, fontSize: 24, color: .black)
        else { throw Failure("didn't typeset") }
        #expect(first.display === second.display)
        #expect(first.display !== bigger.display)
    }

    @Test func invalidSourceStillGetsABox() {
        let size = LaTeXRenderer.size(of: #"\frac{"#, fontSize: 16)
        #expect(size.width >= 60 && size.height > 16)
    }

    /// Other PDF editors only see what PDFKit writes: each formula must stay a
    /// stamp annotation (so it can be moved there), carrying its drawing as an
    /// appearance stream.
    @Test func writtenFormulasAreStampsWithAppearances() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        page.addAnnotation(
            try annotation(#"\frac{1}{2}"#, at: CGPoint(x: 100, y: 500)))
        let data = try #require(document.dataRepresentation())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/Stamp"))
        #expect(text.contains("/AP"))

        let reread = try #require(PDFDocument(data: data)?.page(at: 0))
        let stamp = try #require(reread.annotations.first)
        #expect(stamp.type == "Stamp")
        #expect(stamp.contents == #"\frac{1}{2}"#)
        let rows = darkPixelsPerRow(size: stamp.bounds.size) { context in
            context.translateBy(x: -stamp.bounds.minX, y: -stamp.bounds.minY)
            reread.draw(with: .mediaBox, to: context)
        }
        #expect(
            rows.max()! > Int(stamp.bounds.width * Self.scale) / 2,
            "the written formula lost its bar")
    }

    // MARK: Helpers

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static let scale: CGFloat = 4

    private func annotation(_ source: String, at origin: CGPoint = .zero)
        throws -> LaTeXAnnotation
    {
        guard
            case .formula(let typeset) = LaTeXRenderer.typeset(
                source, fontSize: 16, color: .black)
        else {
            throw Failure("\(source) didn't typeset")
        }
        return LaTeXAnnotation(
            bounds: CGRect(origin: origin, size: typeset.size), source: source,
            fontSize: 16, color: .black)
    }

    private struct Pixel {
        let red: Int, green: Int, blue: Int
    }

    /// Draws into a white bitmap at 4× and returns its pixels, top row first.
    private func pixels(size: CGSize, _ draw: (CGContext) -> Void) -> [Pixel] {
        let width = Int(size.width * Self.scale),
            height = Int(size.height * Self.scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: Self.scale, y: Self.scale)
        draw(context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(width * height)).map {
            Pixel(
                red: Int(bytes[$0 * 4]), green: Int(bytes[$0 * 4 + 1]),
                blue: Int(bytes[$0 * 4 + 2]))
        }
    }

    private func darkPixelsPerRow(size: CGSize, _ draw: (CGContext) -> Void)
        -> [Int]
    {
        let width = Int(size.width * Self.scale)
        let all = pixels(size: size, draw)
        return stride(from: 0, to: all.count, by: width).map { start in
            all[start..<(start + width)].filter {
                $0.red < 128 && $0.green < 128 && $0.blue < 128
            }.count
        }
    }
}
