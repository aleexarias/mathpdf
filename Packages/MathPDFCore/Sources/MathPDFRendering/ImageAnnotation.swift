import AppKit
import CoreText
import MathPDFCore
import MathPDFLaTeX

/// An image on a page, drawn from `ImageCache` at about the size it's shown,
/// or in an exported copy at full size. A plain box until it's loaded, and one
/// saying so if it's missing. On screen it's drawn by its `ImagePage`, not by
/// PDFKit.
public final class ImageAnnotation: UprightAnnotation {
    private let image: ImageReference
    private let cache: ImageCache?
    private let decoded: CGImage?
    /// While the crop is being changed: the bounds are the whole image's, and
    /// what's outside this part, as fractions from its top left, is dimmed.
    public var editingCrop: CGRect? {
        didSet { if editingCrop != oldValue { redraw(bounds) } }
    }

    /// Shown above the pages while it's moved, resized or cropped, and not
    /// drawn with its page meanwhile.
    public var isLifted = false {
        didSet {
            if isLifted != oldValue {
                (page as? ImagePage)?.redrawImages(in: bounds)
            }
        }
    }

    override public var bounds: CGRect {
        didSet { if bounds != oldValue { redraw(oldValue.union(bounds)) } }
    }

    @MainActor
    public convenience init(
        bounds: CGRect, image: ImageReference, cache: ImageCache?,
        pageRotation: Int = 0
    ) {
        self.init(
            bounds: bounds, image: image, cache: cache, decoded: nil,
            pageRotation: pageRotation)
        NotificationCenter.default.addObserver(
            self, selector: #selector(imageLoaded(_:)),
            name: ImageCache.didLoad, object: cache)
    }

    /// For an exported copy: `decoded` is the image at full size.
    @MainActor
    public convenience init(
        bounds: CGRect, image: ImageReference, decoded: CGImage,
        pageRotation: Int = 0
    ) {
        self.init(
            bounds: bounds, image: image, cache: nil, decoded: decoded,
            pageRotation: pageRotation)
    }

    @MainActor
    private init(
        bounds: CGRect, image: ImageReference, cache: ImageCache?,
        decoded: CGImage?, pageRotation: Int
    ) {
        self.image = image
        self.cache = cache
        self.decoded = decoded
        super.init(
            bounds: bounds, minimumShownSize: .zero,
            pageRotation: pageRotation)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func imageLoaded(_ notification: Notification) {
        guard notification.userInfo?["hash"] as? String == image.hash else {
            return
        }
        redraw(bounds)
    }

    private func redraw(_ rect: CGRect) {
        if !isLifted { (page as? ImagePage)?.redrawImages(in: rect) }
    }

    /// The part of the image shown, as fractions from its top left: all of it
    /// while the crop is changed.
    private var part: CGRect {
        editingCrop == nil ? image.crop : ImageReference.uncropped
    }

    /// The whole image, decoded to show its part `size` big at `scale` pixels
    /// a point, and no more than `largest` pixels on its longer side.
    private func lookup(
        showing size: CGSize, scale: CGFloat,
        largest: CGFloat = .greatestFiniteMagnitude
    ) -> ImageCache.Lookup {
        let whole = max(size.width / part.width, size.height / part.height)
        return decoded.map(ImageCache.Lookup.image)
            ?? cache?.image(image, longestSide: min(whole * scale, largest))
            ?? .missing
    }

    /// What it shows `size` big at `scale` pixels a point, and which part of
    /// that; nil while it isn't loaded.
    public func contents(
        showing size: CGSize, scale: CGFloat, largest: CGFloat
    ) -> (image: CGImage, part: CGRect)? {
        guard
            case .image(let decoded) = lookup(
                showing: size, scale: scale, largest: largest)
        else { return nil }
        return (decoded, part)
    }

    override public func drawContent(size: CGSize, in context: CGContext) {
        let crop = part
        let whole = CGSize(
            width: size.width / crop.width, height: size.height / crop.height)
        let lookup = lookup(showing: size, scale: context.pixelsPerPoint)
        switch lookup {
        case .image(let decoded):
            context.clip(to: CGRect(origin: .zero, size: size))
            context.interpolationQuality = .high
            // the crop is from the image's top left; the context's origin is
            // bottom left
            context.draw(
                decoded,
                in: CGRect(
                    x: -crop.minX * whole.width,
                    y: -(1 - crop.maxY) * whole.height,
                    width: whole.width, height: whole.height))
            if let editingCrop {
                dim(outside: editingCrop, of: size, in: context)
            }
        case .loading:
            drawPlaceholder(size: size, in: context, saying: nil)
        case .missing:
            drawPlaceholder(size: size, in: context, saying: "Image missing")
        }
    }

    private func dim(
        outside part: CGRect, of size: CGSize, in context: CGContext
    ) {
        context.addRect(CGRect(origin: .zero, size: size))
        context.addRect(
            CGRect(
                x: part.minX * size.width, y: (1 - part.maxY) * size.height,
                width: part.width * size.width,
                height: part.height * size.height))
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        context.fillPath(using: .evenOdd)
    }

    private func drawPlaceholder(
        size: CGSize, in context: CGContext, saying message: String?
    ) {
        let box = CGRect(origin: .zero, size: size)
        // not label colours: the page stays white in dark mode
        context.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        context.fill(box)
        context.setStrokeColor(NSColor.gray.cgColor)
        context.setLineWidth(1)
        context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
        guard let message else { return }
        let font = NSFont.systemFont(ofSize: min(12, size.height / 3))
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: message,
                attributes: [
                    .font: font, .foregroundColor: NSColor.darkGray,
                ]))
        let text = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: (size.width - text.width) / 2 - text.minX,
            y: (size.height - text.height) / 2 - text.minY)
        CTLineDraw(line, context)
    }
}
