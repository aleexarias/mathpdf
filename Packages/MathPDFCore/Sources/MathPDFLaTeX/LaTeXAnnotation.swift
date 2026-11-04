import AppKit
import CoreText
import PDFKit
import SwiftMath

/// A LaTeX formula on a page: a stamp annotation that draws its typeset
/// formula as vector glyphs, so it stays sharp at any zoom. Its source is kept
/// as the annotation's contents. Invalid source is drawn as a red box showing
/// the source; empty source (while it's still being written) as a dashed
/// placeholder.
public final class LaTeXAnnotation: PDFAnnotation {
    private let display: MTMathListDisplay?
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
        bounds: CGRect, source: String, fontSize: CGFloat, color: NSColor
    ) {
        if case .formula(let typeset) = LaTeXRenderer.typeset(
            source, fontSize: fontSize, color: color)
        {
            display = typeset.display
        } else {
            display = nil
        }
        self.source = source
        self.fontSize = fontSize
        self.textColor = color
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        contents = source
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    override public func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if isSelected {
            context.setFillColor(
                NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            context.addPath(
                CGPath(
                    roundedRect: bounds, cornerWidth: 3, cornerHeight: 3,
                    transform: nil))
            context.fillPath()
        }
        if let display {
            context.translateBy(x: bounds.minX, y: bounds.minY)
            LaTeXRenderer.draw(display, in: context)
        } else {
            // CoreText would otherwise inherit PDFKit's text matrix
            context.textMatrix = .identity
            drawPlaceholder(in: context)
        }
    }

    private func drawPlaceholder(in context: CGContext) {
        let isEmpty = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let color = isEmpty ? NSColor.secondaryLabelColor : NSColor.systemRed
        let box = bounds.insetBy(dx: 0.75, dy: 0.75)
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
