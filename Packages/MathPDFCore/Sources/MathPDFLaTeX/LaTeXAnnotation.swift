import AppKit
import CoreText
import MathPDFCore
import PDFKit
import SwiftMath

/// A LaTeX formula on a page: a stamp annotation that draws its typeset
/// formula as vector glyphs, so it stays sharp at any zoom. It typesets
/// `expanded` if there is one, and the source is kept as the annotation's
/// contents. Invalid source is drawn as a red box showing the source; empty
/// source (while it's still being written) as a dashed placeholder.
public final class LaTeXAnnotation: PDFAnnotation {
    private let display: MTMathListDisplay?
    /// At least this big, so nothing is clipped: a formula saved earlier was
    /// measured with whichever letters were drawn then.
    private let minimumSize: CGSize
    private let pageRotation: Int
    private let source: String
    private let fontSize: CGFloat
    private let textColor: NSColor
    /// Drawn with a light tint behind it, since black can't get "more vivid"
    /// like other colours.
    public var isSelected = false {
        didSet {
            // PDFKit keeps its own drawing of the formula and redraws it when
            // one of the annotation's properties is set;
            // annotationsChanged(on:) doesn't reach it. Without this the tint
            // would stay on after the formula is deselected.
            if isSelected != oldValue { bounds = bounds }
        }
    }

    @MainActor
    public init(
        bounds: CGRect, source: String, expanded: String? = nil,
        fontSize: CGFloat, color: NSColor, pageRotation: Int = 0
    ) {
        self.pageRotation = pageRotation
        if case .formula(let typeset) = LaTeXRenderer.typeset(
            expanded ?? source, fontSize: fontSize, color: color)
        {
            display = typeset.display
            minimumSize = PageFrame(box: .zero, rotation: pageRotation).turned(
                typeset.size)
        } else {
            display = nil
            minimumSize = .zero
        }
        self.source = source
        self.fontSize = fontSize
        self.textColor = color
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.bounds = bounds
        contents = source
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    override public var bounds: CGRect {
        get { super.bounds }
        set {
            var fitted = newValue
            fitted.size.width = max(fitted.width, minimumSize.width)
            fitted.size.height = max(fitted.height, minimumSize.height)
            super.bounds = fitted
        }
    }

    override public func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        let (rect, turn) = placement(for: box, in: context)
        if isSelected {
            context.setFillColor(
                NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            context.addPath(
                CGPath(
                    roundedRect: rect, cornerWidth: 3, cornerHeight: 3,
                    transform: nil))
            context.fillPath()
        }
        let size = PageFrame(box: .zero, rotation: turn).turned(rect.size)
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(turn) * .pi / 180)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        if let display {
            LaTeXRenderer.draw(display, in: context)
        } else {
            // CoreText would otherwise inherit PDFKit's text matrix
            context.textMatrix = .identity
            drawPlaceholder(size: size, in: context)
        }
    }

    /// Where the formula goes in `context`, and how far to turn it to read
    /// upright. For its own layer, or an exported appearance, the context is
    /// in page coordinates and clipped to the bounds, and the result turns
    /// with the page, so it's turned back. As part of a whole page, as for a
    /// thumbnail, the context is the page as shown, and nothing turns.
    private func placement(for box: PDFDisplayBox, in context: CGContext)
        -> (rect: CGRect, turn: Int)
    {
        guard let page else { return (bounds, 0) }
        let clip = context.boundingBoxOfClipPath
        if clip.width <= bounds.width + 2, clip.height <= bounds.height + 2 {
            return (bounds, pageRotation)
        }
        let frame = PageFrame(
            box: page.bounds(for: box), rotation: pageRotation)
        return (frame.shown(bounds), 0)
    }

    private func drawPlaceholder(size: CGSize, in context: CGContext) {
        let isEmpty = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        // not a label color: the page stays white in dark mode
        let color = isEmpty ? NSColor.gray : NSColor.systemRed
        let box = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.addPath(
            CGPath(
                roundedRect: box, cornerWidth: 3, cornerHeight: 3,
                transform: nil))
        context.strokePath()

        let text = NSAttributedString(
            string: isEmpty ? "LaTeX" : source,
            attributes: [
                .font: LaTeXRenderer.errorFont(fontSize: fontSize),
                .foregroundColor: color,
            ])
        let line = CTLineCreateWithAttributedString(text)
        let truncated = CTLineCreateTruncatedLine(
            line, Double(box.width - 8), .end,
            CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "…", attributes: [.foregroundColor: color])))
        let textBounds = CTLineGetBoundsWithOptions(truncated ?? line, [])
        context.textPosition = CGPoint(
            x: box.minX + 4, y: box.midY - textBounds.midY)
        CTLineDraw(truncated ?? line, context)
    }
}
