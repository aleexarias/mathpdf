import AppKit
import CoreText
import SwiftMath

/// A LaTeX formula on a page. It typesets `expanded` if there is one, and the
/// source is kept as the annotation's contents. Invalid source is drawn as a
/// red box showing the source; empty source (while it's still being written)
/// as a dashed placeholder.
public final class LaTeXAnnotation: UprightAnnotation {
    private let display: MTMathListDisplay?
    private let source: String
    private let fontSize: CGFloat

    /// The bounds are at least the formula's size, so nothing is clipped: a
    /// formula saved earlier was measured with whichever letters were drawn
    /// then.
    @MainActor
    public init(
        bounds: CGRect, source: String, expanded: String? = nil,
        fontSize: CGFloat, color: NSColor, pageRotation: Int = 0
    ) {
        let typeset: LaTeXRenderer.Typeset? =
            if case .formula(let typeset) = LaTeXRenderer.typeset(
                expanded ?? source, fontSize: fontSize, color: color)
            {
                typeset
            } else {
                nil
            }
        display = typeset?.display
        self.source = source
        self.fontSize = fontSize
        super.init(
            bounds: bounds, minimumShownSize: typeset?.size ?? .zero,
            pageRotation: pageRotation)
        contents = source
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    override public func drawContent(size: CGSize, in context: CGContext) {
        if let display {
            LaTeXRenderer.draw(display, in: context)
        } else {
            drawPlaceholder(size: size, in: context)
        }
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
