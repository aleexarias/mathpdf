import AppKit
import CoreText
import MathPDFCore
import MathPDFLaTeX
import PDFKit
import Testing

@testable import MathPDFRendering

/// What's written on a rotated page reads upright, in the right place, however
/// it's drawn: as a whole page, in its own layer, and exported.
@MainActor
struct RotatedPagesTests {
    private static let black = RGBAColor(red: 0, green: 0, blue: 0)
    private static let source = #"\frac{a}{b}+x^2+y^2"#
    private static let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let scale: CGFloat = 2

    private func document(rotation: Int) -> PDFDocument {
        Self.emptyDocument(rotation: rotation)
    }

    private static func emptyDocument(rotation: Int) -> PDFDocument {
        let data = NSMutableData()
        var box = pageBox
        let context = CGContext(
            consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = PDFDocument(data: data as Data)!
        document.page(at: 0)!.rotation = rotation
        return document
    }

    /// A grid of whether each pixel has ink.
    private struct Ink {
        let width: Int
        let height: Int
        let cells: [Bool]

        /// The smallest box around the ink.
        var box: CGRect {
            var (minX, minY, maxX, maxY) = (width, height, -1, -1)
            for y in 0..<height {
                for x in 0..<width where cells[y * width + x] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return .null }
            return CGRect(
                x: minX, y: minY, width: maxX - minX + 1,
                height: maxY - minY + 1)
        }

        /// The ink alone, cut out, so two drawings can be compared wherever
        /// they are.
        var trimmed: Ink {
            let box = box
            guard !box.isNull else { return self }
            var cut: [Bool] = []
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    cut.append(cells[y * width + x])
                }
            }
            return Ink(
                width: Int(box.width), height: Int(box.height), cells: cut)
        }

        /// Turned clockwise by `degrees`, as the page turns.
        func turned(_ degrees: Int) -> Ink {
            switch degrees {
            case 90:
                var out = [Bool](repeating: false, count: cells.count)
                for y in 0..<height {
                    for x in 0..<width {
                        out[x * height + (height - 1 - y)] =
                            cells[y * width + x]
                    }
                }
                return Ink(width: height, height: width, cells: out)
            case 180: return turned(90).turned(90)
            case 270: return turned(90).turned(90).turned(90)
            default: return self
            }
        }

        /// How much of the ink of two drawings coincides, to within a pixel,
        /// since what's drawn at different places differs at its very edges.
        func overlap(with other: Ink) -> Double {
            guard abs(width - other.width) <= 3,
                abs(height - other.height) <= 3
            else { return 0 }
            func hasInk(_ ink: Ink, _ x: Int, _ y: Int) -> Bool {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let (px, py) = (x + dx, y + dy)
                        if px >= 0, py >= 0, px < ink.width, py < ink.height,
                            ink.cells[py * ink.width + px]
                        {
                            return true
                        }
                    }
                }
                return false
            }
            var inked = 0
            var matched = 0
            for (a, b) in [(self, other), (other, self)] {
                for y in 0..<a.height {
                    for x in 0..<a.width where a.cells[y * a.width + x] {
                        inked += 1
                        if hasInk(b, x, y) { matched += 1 }
                    }
                }
            }
            return inked == 0 ? 0 : Double(matched) / Double(inked)
        }
    }

    private static func ink(
        width: CGFloat, height: CGFloat, _ draw: (CGContext) -> Void
    ) -> Ink {
        let pixelWidth = Int(width * Self.scale)
        let pixelHeight = Int(height * Self.scale)
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(
            CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: Self.scale, y: Self.scale)
        draw(context)
        let pixels = UnsafeBufferPointer(
            start: context.data!.assumingMemoryBound(to: UInt8.self),
            count: pixelWidth * pixelHeight)
        return Ink(
            width: pixelWidth, height: pixelHeight,
            cells: pixels.map { $0 < 128 })
    }

    /// The whole page as it's seen, as for a thumbnail. Rows run top to
    /// bottom.
    private static func wholePage(_ page: PDFPage) -> Ink {
        let size = PageFrame(
            box: page.bounds(for: .cropBox), rotation: page.rotation
        ).shownSize
        return ink(width: size.width, height: size.height) {
            page.draw(with: .cropBox, to: $0)
        }
    }

    private static func formula(on page: PDFPage, at centre: CGPoint)
        -> LaTeXAnnotation
    {
        let frame = PageFrame(
            box: page.bounds(for: .cropBox), rotation: page.rotation)
        let size = LaTeXRenderer.size(of: Self.source, fontSize: 24)
        let mark = LaTeXAnnotation(
            bounds: frame.box(ofShownSize: size, centredAt: centre),
            source: Self.source, fontSize: 24, color: .black,
            pageRotation: page.rotation)
        page.addAnnotation(mark)
        return mark
    }

    /// A formula upright on an unturned page, to compare the others with.
    private static let upright: Ink = {
        let page = emptyDocument(rotation: 0).page(at: 0)!
        _ = formula(on: page, at: CGPoint(x: 300, y: 400))
        return wholePage(page).trimmed
    }()

    /// As in a thumbnail: it reads upright, at its place on the page as seen.
    @Test(arguments: [0, 90, 180, 270])
    func onAWholePage(rotation: Int) {
        let page = document(rotation: rotation).page(at: 0)!
        let centre = CGPoint(x: 200, y: 300)
        _ = Self.formula(on: page, at: centre)
        let drawn = Self.wholePage(page)
        #expect(drawn.trimmed.overlap(with: Self.upright) > 0.95)

        let frame = PageFrame(box: Self.pageBox, rotation: rotation)
        let expected = frame.shown(centre)
        let box = drawn.box
        // the grid's rows run from the top of the context
        #expect(abs(box.midX / Self.scale - expected.x) < 15)
        #expect(
            abs(
                (CGFloat(drawn.height) - box.midY) / Self.scale - expected.y)
                < 15)
    }

    /// A page's visible part needn't start at its corner.
    @Test(arguments: [0, 90, 180, 270])
    func onACroppedPage(rotation: Int) {
        let page = document(rotation: rotation).page(at: 0)!
        let crop = CGRect(x: 100, y: 150, width: 400, height: 500)
        page.setBounds(crop, for: .cropBox)
        let centre = CGPoint(x: 260, y: 330)
        _ = Self.formula(on: page, at: centre)
        let drawn = Self.wholePage(page)
        let overlap = drawn.trimmed.overlap(with: Self.upright)
        #expect(overlap > 0.95, "overlap \(overlap)")
        let expected = PageFrame(box: crop, rotation: rotation).shown(centre)
        let box = drawn.box
        #expect(abs(box.midX / Self.scale - expected.x) < 15)
        #expect(
            abs(
                (CGFloat(drawn.height) - box.midY) / Self.scale - expected.y)
                < 15)
    }

    /// As in the viewer, and in an exported appearance: drawn in page
    /// coordinates and clipped to its bounds, then turned with the page.
    @Test(arguments: [0, 90, 180, 270])
    func inItsOwnLayer(rotation: Int) {
        let page = document(rotation: rotation).page(at: 0)!
        let mark = Self.formula(on: page, at: CGPoint(x: 300, y: 400))
        let bounds = mark.bounds
        let drawn = Self.ink(width: bounds.width, height: bounds.height) {
            $0.translateBy(x: -bounds.minX, y: -bounds.minY)
            $0.clip(to: bounds)
            mark.draw(with: .mediaBox, in: $0)
        }
        let overlap = drawn.turned(rotation).trimmed.overlap(
            with: Self.upright)
        #expect(overlap > 0.95, "overlap \(overlap)")
    }

    /// The direction matters: turning the wrong way must not pass.
    @Test func turningTheWrongWayIsNoMatch() {
        let page = document(rotation: 90).page(at: 0)!
        let mark = Self.formula(on: page, at: CGPoint(x: 300, y: 400))
        let bounds = mark.bounds
        let drawn = Self.ink(width: bounds.width, height: bounds.height) {
            $0.translateBy(x: -bounds.minX, y: -bounds.minY)
            $0.clip(to: bounds)
            mark.draw(with: .mediaBox, in: $0)
        }
        let overlap = drawn.turned(270).trimmed.overlap(
            with: Self.upright)
        #expect(overlap < 0.8, "overlap \(overlap)")
    }

    @Test(arguments: [0, 90, 180, 270])
    func exported(rotation: Int) throws {
        let original = try #require(
            document(rotation: rotation).dataRepresentation())
        let frame = PageFrame(box: Self.pageBox, rotation: rotation)
        let centre = CGPoint(x: 200, y: 300)
        let size = LaTeXRenderer.size(of: Self.source, fontSize: 24)
        let exported = try PDFExporter.annotatedPDF(
            original: original,
            annotations: [
                Annotation(
                    kind: .latex(source: Self.source, fontSize: 24),
                    pageIndex: 0,
                    bounds: frame.box(ofShownSize: size, centredAt: centre),
                    color: Self.black)
            ])
        let page = try #require(PDFDocument(data: exported)?.page(at: 0))
        #expect(page.rotation == rotation)
        let drawn = Self.wholePage(page)
        let overlap = drawn.trimmed.overlap(with: Self.upright)
        #expect(overlap > 0.9, "overlap \(overlap)")
        let expected = frame.shown(centre)
        #expect(abs(drawn.box.midX / Self.scale - expected.x) < 15)
    }

    /// A box saved earlier, the wrong way round, still isn't clipped.
    @Test func aNarrowBoxGrowsTheRightWayRound() {
        let size = LaTeXRenderer.size(of: Self.source, fontSize: 24)
        let mark = LaTeXAnnotation(
            bounds: CGRect(x: 100, y: 100, width: 1, height: 1),
            source: Self.source, fontSize: 24, color: .black, pageRotation: 90)
        #expect(mark.bounds.width == size.height)
        #expect(mark.bounds.height == size.width)
    }

    /// An underline runs along the text on screen, under it, not across it.
    @Test(arguments: [0, 90, 180, 270])
    func anUnderlineRunsAlongItsLine(rotation: Int) {
        let page = document(rotation: rotation).page(at: 0)!
        let frame = PageFrame(box: Self.pageBox, rotation: rotation)
        let line = frame.onPage(CGRect(x: 100, y: 300, width: 300, height: 30))
        page.addAnnotation(
            AnnotationMarks.markup(
                .underline, [line], .black, pageRotation: rotation))
        let drawn = Self.wholePage(page)
        let box = drawn.box
        #expect(box.width / Self.scale > 250)
        #expect(box.height / Self.scale < 10)
        // at the bottom of the line, as seen
        let fromBottom = CGFloat(drawn.height) - box.midY
        #expect(abs(fromBottom / Self.scale - 300) < 10)
    }

    /// PDFKit turns a text box's text upright by itself, given the right
    /// bounds.
    @Test(arguments: [0, 90, 180, 270])
    func aTextBoxStaysOnOneLine(rotation: Int) {
        let page = document(rotation: rotation).page(at: 0)!
        let frame = PageFrame(box: Self.pageBox, rotation: rotation)
        let text = "a long line of words"
        let size = TextBoxStyle.size(of: text, fontSize: 18)
        let annotation = Annotation(
            kind: .textBox(text: text, fontSize: 18), pageIndex: 0,
            bounds: frame.box(
                ofShownSize: size, centredAt: CGPoint(x: 300, y: 400)),
            color: Self.black)
        for (mark, _) in AnnotationMarks.marks(
            for: annotation, pageRotation: rotation)
        {
            page.addAnnotation(mark)
        }
        let box = Self.wholePage(page).box
        #expect(box.width > box.height * 5)
        #expect(box.width / Self.scale > size.width * 0.8)
    }

    // MARK: Boxes saved before this was handled

    private func formulaAnnotation(_ bounds: CGRect) -> Annotation {
        Annotation(
            kind: .latex(source: Self.source, fontSize: 24), pageIndex: 0,
            bounds: bounds, color: Self.black)
    }

    private func textBoxAnnotation(_ bounds: CGRect) -> Annotation {
        Annotation(
            kind: .textBox(text: "a line of words", fontSize: 14),
            pageIndex: 0, bounds: bounds, color: Self.black)
    }

    @Test(arguments: [90, 270])
    func aSavedFormulaIsPutTheRightWayRound(rotation: Int) {
        let size = LaTeXRenderer.size(of: Self.source, fontSize: 24)
        let saved = CGRect(
            x: 200, y: 300, width: size.width, height: size.height)
        let corrected = SidewaysBoxes.corrected(
            [formulaAnnotation(saved)], in: document(rotation: rotation))
        let bounds = corrected[0].bounds
        #expect(bounds.size == CGSize(width: size.height, height: size.width))
        #expect(bounds.midX == saved.midX && bounds.midY == saved.midY)
    }

    @Test(arguments: [90, 270])
    func aSavedTextBoxIsPutTheRightWayRound(rotation: Int) {
        let size = TextBoxStyle.size(of: "a line of words", fontSize: 14)
        let saved = CGRect(
            x: 200, y: 300, width: size.width, height: size.height)
        let corrected = SidewaysBoxes.corrected(
            [textBoxAnnotation(saved)], in: document(rotation: rotation))
        let bounds = corrected[0].bounds
        #expect(bounds.size == CGSize(width: size.height, height: size.width))
        #expect(bounds.midX == saved.midX && bounds.midY == saved.midY)
    }

    /// Once corrected, or made since, it's left alone: this runs at every
    /// load.
    @Test func correctingTwiceChangesNothing() {
        let document = document(rotation: 90)
        let formula = LaTeXRenderer.size(of: Self.source, fontSize: 24)
        let box = TextBoxStyle.size(of: "a line of words", fontSize: 14)
        let annotations = [
            formulaAnnotation(
                CGRect(
                    x: 200, y: 300, width: formula.width,
                    height: formula.height)),
            textBoxAnnotation(
                CGRect(x: 200, y: 500, width: box.width, height: box.height)),
        ]
        let once = SidewaysBoxes.corrected(annotations, in: document)
        #expect(once != annotations)
        #expect(SidewaysBoxes.corrected(once, in: document) == once)
    }

    /// A box the user made narrow, wrapped over several lines, is tall for its
    /// own reasons.
    @Test func aWrappedTextBoxMadeSinceIsLeftAlone() {
        let text = "several words that wrap over a few lines here"
        let size = TextBoxStyle.size(of: text, fontSize: 14, width: 80)
        let annotation = Annotation(
            kind: .textBox(text: text, fontSize: 14), pageIndex: 0,
            // the right way round for a sideways page
            bounds: CGRect(
                x: 200, y: 300, width: size.height, height: size.width),
            color: Self.black)
        #expect(
            SidewaysBoxes.corrected([annotation], in: document(rotation: 90))
                == [annotation])
    }

    /// Unturned and upside down pages have nothing to correct.
    @Test(arguments: [0, 180])
    func otherPagesAreLeftAlone(rotation: Int) {
        let annotations = [
            formulaAnnotation(
                CGRect(x: 200, y: 300, width: 30, height: 90)),
            textBoxAnnotation(CGRect(x: 200, y: 500, width: 20, height: 90)),
        ]
        #expect(
            SidewaysBoxes.corrected(
                annotations, in: document(rotation: rotation)) == annotations)
    }
}
