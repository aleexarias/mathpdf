import MathPDFCore
import PDFKit

extension AnnotationPDFView {
    /// Sets the zoom straight away, keeping what's at the centre of the
    /// uncovered area in place.
    func zoom(to scale: CGFloat) {
        fit = nil
        let anchor = zoomAnchor()
        scaleFactor = scale.clamped(to: scaleRange)
        updateGeometry()
        if let anchor { restore(anchor) }
    }

    struct ZoomAnimation {
        let link: CADisplayLink
        let anchor: ZoomAnchor?
        let start: CGFloat
        let end: CGFloat
        let began: CFTimeInterval
        let completion: (() -> Void)?
    }
    private static let zoomDuration: CFTimeInterval = 0.32

    /// Eases the zoom to `target`, around the centre of the uncovered area.
    /// It moves evenly on a log scale, so zooming in and out feel the same,
    /// and a step is taken for each frame the display shows: a timer drifts
    /// against the display and stutters.
    func animateZoom(to target: CGFloat, then completion: (() -> Void)? = nil)
    {
        cancelZoomAnimation()
        fit = nil
        let end = target.clamped(to: scaleRange)
        guard window != nil, scaleFactor > 0, abs(end - scaleFactor) > 0.001
        else {
            completion?()
            return
        }
        let link = displayLink(target: self, selector: #selector(zoomStep))
        zoomAnimation = ZoomAnimation(
            link: link, anchor: zoomAnchor(), start: scaleFactor, end: end,
            began: CACurrentMediaTime(), completion: completion)
        link.add(to: .main, forMode: .common)
    }

    /// Stops where it is; the animation's completion isn't called.
    func cancelZoomAnimation() {
        zoomAnimation?.link.invalidate()
        zoomAnimation = nil
    }

    @objc private func zoomStep(_ link: CADisplayLink) {
        guard let zoom = zoomAnimation else { return link.invalidate() }
        let time = min(
            1, max(0, (link.targetTimestamp - zoom.began) / Self.zoomDuration))
        // ease in and out: no sudden start or stop
        let progress = time * time * (3 - 2 * time)
        scaleFactor = zoom.start * pow(zoom.end / zoom.start, progress)
        updateGeometry()
        if let anchor = zoom.anchor { restore(anchor) }
        if time >= 1 {
            cancelZoomAnimation()
            zoom.completion?()
        }
    }

    /// Pinching zooms around the centre of the uncovered area.
    override func magnify(with event: NSEvent) {
        guard editor?.isEditingItem != true else { return }
        zoom(to: scaleFactor * (1 + event.magnification))
    }

    override func smartMagnify(with event: NSEvent) {
        guard editor?.isEditingItem != true else { return }
        fit = nil
        super.smartMagnify(with: event)
    }

    /// A point on a page and where it is in the view, kept still while
    /// zooming.
    struct ZoomAnchor {
        let page: PDFPage
        let pagePoint: CGPoint
        let viewPoint: CGPoint
    }

    /// The centre of the uncovered area.
    func zoomAnchor() -> ZoomAnchor? {
        let center = CGPoint(x: uncoveredRect.midX, y: uncoveredRect.midY)
        guard let page = page(for: center, nearest: true) else { return nil }
        return ZoomAnchor(
            page: page, pagePoint: convert(center, to: page), viewPoint: center
        )
    }

    /// Scrolls so the anchor's page point is back where it was in the view, or
    /// at `viewPoint`.
    func restore(_ anchor: ZoomAnchor, at viewPoint: CGPoint? = nil) {
        let target = viewPoint ?? anchor.viewPoint
        guard let documentView,
            let scrollView = documentView.enclosingScrollView
        else { return }
        let clip = scrollView.contentView
        let scale = clip.pageUnitsPerPoint.map { 1 / $0 } ?? scaleFactor
        let now = convert(anchor.pagePoint, from: anchor.page)
        var origin = clip.bounds.origin
        origin.x += (now.x - target.x) / scale
        origin.y +=
            (now.y - target.y) / scale
            * (documentView.isFlipped == isFlipped ? 1 : -1)
        // Never past the document's edges: that would hold only until the next
        // layout, then snap back.
        origin = clamped(origin, in: scrollView)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        centerIfNarrower()
    }

    /// Avoids `constrainBoundsRect`, which in two-page layouts also moves
    /// positions well inside the document. Where the document fits, PDFKit's
    /// own position is kept, as it centres the pages there.
    func clamped(
        _ origin: NSPoint, in scrollView: NSScrollView
    ) -> NSPoint {
        let current = scrollView.contentView.bounds.origin
        let limits = scrollLimits(of: scrollView)
        return NSPoint(
            x: limits.x.map { origin.x.clamped(to: $0) } ?? current.x,
            y: limits.y.map { origin.y.clamped(to: $0) } ?? current.y)
    }

    /// The clip view origins the document can be scrolled between; nil on
    /// an axis it fits along.
    func scrollLimits(
        of scrollView: NSScrollView
    ) -> (x: ClosedRange<CGFloat>?, y: ClosedRange<CGFloat>?) {
        let clip = scrollView.contentView
        guard let documentView, clip.frame.width > 0 else { return (nil, nil) }
        func limits(_ least: CGFloat, _ most: CGFloat) -> ClosedRange<CGFloat>?
        {
            most > least + 0.5 ? least...most : nil
        }
        // Not `documentRect`, which is never smaller than the clip view.
        let document = documentView.frame
        // In page units, with room for a horizontal scroll bar.
        let insets = clip.contentInsets
        let (low, high) =
            clip.isFlipped
            ? (insets.top, insets.bottom) : (insets.bottom, insets.top)
        return (
            limits(
                document.minX - leftInset(of: scrollView),
                document.maxX - clip.bounds.width),
            limits(
                document.minY - low,
                document.maxY - clip.bounds.height + high)
        )
    }
}
