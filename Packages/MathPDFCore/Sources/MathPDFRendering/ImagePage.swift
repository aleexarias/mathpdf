import MathPDFCore
import PDFKit
import os

/// A document whose pages draw their images themselves.
public final class ImageDocument: PDFDocument {
    override public var pageClass: AnyClass { ImagePage.self }

    /// Each page's images, kept here as PDFKit makes pages without the
    /// stored properties of a Swift subclass, and draws them on other
    /// threads.
    fileprivate let images = OSAllocatedUnfairLock<
        [ObjectIdentifier: [ImageAnnotation]]
    >(uncheckedState: [:])
}

/// A page that draws its images as part of itself. PDFKit draws a page in
/// tiles covering what's on screen, but gives each of its annotations a
/// layer as big as the whole annotation at the current zoom, even one it
/// doesn't display: gigabytes for a large image zoomed in. So an image added
/// to the page is kept out of PDFKit's sight, and drawn with the page.
public final class ImagePage: PDFPage {
    /// Posted with the page when its images change, as PDFKit doesn't know
    /// to draw it again; `userInfo["rect"]` is the part that changed, on the
    /// page.
    public static let imagesChanged = Notification.Name(
        "ImagePageImagesChanged")
    /// Posted on the main thread after part of a page with images was drawn
    /// on screen. `userInfo`: "page", the page's `ObjectIdentifier`; "rect",
    /// the part drawn, and "images", the bounds of the images drawn, on the
    /// page; "scale", pixels drawn per point of the page, as PDFKit draws a
    /// rough whole page before the sharp parts.
    public static let didDrawImages = Notification.Name(
        "ImagePageDidDrawImages")

    private var imageDocument: ImageDocument? { document as? ImageDocument }

    private var images: [ImageAnnotation] {
        let id = ObjectIdentifier(self)
        return imageDocument?.images.withLockUnchecked { $0[id] } ?? []
    }

    override public func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard
            let drawn = drawImages(
                for: box, in: context, includingLifted: false)
        else { return }
        let id = ObjectIdentifier(self)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.didDrawImages, object: nil,
                userInfo: [
                    "page": id, "rect": drawn.rect, "images": drawn.images,
                    "scale": drawn.scale,
                ])
        }
    }

    /// The part of the page drawn, the bounds of the images drawn there, and
    /// pixels per point. A lifted image is shown above the page instead,
    /// except in a thumbnail.
    private func drawImages(
        for box: PDFDisplayBox, in context: CGContext, includingLifted: Bool
    ) -> (rect: CGRect, images: [CGRect], scale: CGFloat)? {
        let images = images.filter { includingLifted || !$0.isLifted }
        guard !images.isEmpty else { return nil }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(transform(for: box))
        for image in images { image.drawOnPage(in: context) }
        return (
            context.boundingBoxOfClipPath, images.map(\.bounds),
            context.pixelsPerPoint
        )
    }

    override public func addAnnotation(_ annotation: PDFAnnotation) {
        guard let image = annotation as? ImageAnnotation, let imageDocument
        else { return super.addAnnotation(annotation) }
        let id = ObjectIdentifier(self)
        imageDocument.images.withLockUnchecked {
            $0[id, default: []].append(image)
        }
        image.page = self
        redrawImages(in: image.bounds)
    }

    override public func removeAnnotation(_ annotation: PDFAnnotation) {
        guard let image = annotation as? ImageAnnotation, let imageDocument
        else { return super.removeAnnotation(annotation) }
        let id = ObjectIdentifier(self)
        imageDocument.images.withLockUnchecked {
            $0[id]?.removeAll { $0 === image }
        }
        image.page = nil
        redrawImages(in: image.bounds)
    }

    /// PDFKit's thumbnails don't go through `draw(with:to:)`.
    override public func thumbnail(of size: NSSize, for box: PDFDisplayBox)
        -> NSImage
    {
        let shown = PageFrame(box: bounds(for: box), rotation: rotation)
            .shownSize
        let scale = min(size.width / shown.width, size.height / shown.height)
        guard !images.isEmpty,
            let image = drawn(
                CGRect(origin: .zero, size: shown), in: box, scale: scale,
                includingLifted: true)
        else { return super.thumbnail(of: size, for: box) }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height))
    }

    /// The part of the page in `rect`, as shown, without its lifted images:
    /// how it looks there once PDFKit has drawn it again, which it starts a
    /// tenth of a second after it's asked to. Drawn on another thread, as
    /// PDFKit draws its pages, and handed to `use` on the main one.
    public func picture(
        of rect: CGRect, in box: PDFDisplayBox, scale: CGFloat,
        then use: @escaping @MainActor @Sendable (CGImage?) -> Void
    ) {
        nonisolated(unsafe) let page = self
        let shown = PageFrame(box: bounds(for: box), rotation: rotation)
            .shown(rect)
        DispatchQueue.global(qos: .userInteractive).async {
            let picture = page.drawn(
                shown, in: box, scale: scale, includingLifted: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { use(picture) }
            }
        }
    }

    /// `rect` of the page as shown, on white, `scale` pixels a point.
    private func drawn(
        _ rect: CGRect, in box: PDFDisplayBox, scale: CGFloat,
        includingLifted: Bool
    ) -> CGImage? {
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        super.draw(with: box, to: context)
        _ = drawImages(
            for: box, in: context, includingLifted: includingLifted)
        return context.makeImage()
    }

    /// Has the part of the page in `rect` drawn again, as images there
    /// changed.
    public func redrawImages(in rect: CGRect) {
        NotificationCenter.default.post(
            name: Self.imagesChanged, object: self,
            userInfo: ["rect": NSValue(rect: rect)])
    }
}

extension CGContext {
    /// Device pixels per unit drawn, along a side.
    var pixelsPerPoint: CGFloat {
        let device = userSpaceToDeviceSpaceTransform
        return max(sqrt(abs(device.a * device.d - device.b * device.c)), 0.001)
    }
}

/// A PDF view that draws an `ImagePage` again when its images change.
open class ImagePDFView: PDFView {
    override public init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(imagesChanged(_:)),
            name: ImagePage.imagesChanged, object: nil)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Only that part, so moving an image doesn't draw the whole page again
    /// at every step.
    @objc private func imagesChanged(_ notification: Notification) {
        guard let page = notification.object as? PDFPage,
            page.document === document,
            let rect = (notification.userInfo?["rect"] as? NSValue)?.rectValue
        else { return }
        setNeedsDisplay(convert(rect, from: page).insetBy(dx: -1, dy: -1))
    }
}
