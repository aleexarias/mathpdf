import AppKit
import MathPDFCore
import PDFKit

/// A stamp annotation that draws its own content, upright on screen whatever
/// the page's rotation, and as vector graphics, so it stays sharp at any zoom
/// and travels into exported PDFs as the stamp's appearance. Subclasses draw
/// the content in `drawContent(size:in:)`.
open class UprightAnnotation: PDFAnnotation {
    /// At least this big, so the content is never clipped.
    private let minimumSize: CGSize
    private let pageRotation: Int
    /// Drawn with a light tint behind it, since black can't get "more vivid"
    /// like other colours.
    public var isSelected = false {
        didSet {
            // PDFKit keeps its own drawing of the annotation and redraws it
            // when one of its properties is set; annotationsChanged(on:)
            // doesn't reach it. Without this the tint would stay on after the
            // annotation is deselected.
            if isSelected != oldValue { bounds = bounds }
        }
    }

    /// `minimumShownSize` is as seen on screen.
    public init(
        bounds: CGRect, minimumShownSize: CGSize, pageRotation: Int
    ) {
        self.pageRotation = pageRotation
        minimumSize = PageFrame(box: .zero, rotation: pageRotation).turned(
            minimumShownSize)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.bounds = bounds
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

    /// Draws the content in a box of `size`, as seen on screen, with its
    /// origin at the context's origin, bottom left.
    open func drawContent(size: CGSize, in context: CGContext) {}

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
        // CoreText would otherwise inherit PDFKit's text matrix
        context.textMatrix = .identity
        drawContent(size: size, in: context)
    }

    /// Where the content goes in `context`, and how far to turn it to read
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
}
