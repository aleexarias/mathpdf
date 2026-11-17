import MathPDFCore
import PDFKit

/// A PDFView that hands clicks, drags, Delete/Esc and right-clicks on mathpdf
/// annotations to the annotation editor, and pastes copied pages after the
/// page on screen. Everything else (text selection, links, scrolling) works
/// as usual.
final class AnnotationPDFView: PDFView {
    weak var editor: AnnotationEditor?
    weak var viewer: Viewer?

    var drag: (page: PDFPage, start: CGPoint)?
    /// Set while PDFView handles a click or text selection that the active
    /// tool should use when it ends. Cleared once used, so a gesture is never
    /// used twice.
    var toolGestureActive = false
    /// Delivers mouse moves, for the cursor over a text box's edge.
    var mouseMovedTracking: NSTrackingArea?

    // The view reaches under the translucent toolbar and sidebar. The scroll
    // view's insets keep the pages clear of them, and the pages are fitted
    // to the uncovered area. `ClipConstraint` makes PDFKit honour the left
    // inset.

    /// The fit the pages are kept at as the uncovered area changes (Zoom to
    /// Fit). Nil once the zoom is set by hand.
    var fit: PageFit? = .width {
        didSet { if fit != nil { updateGeometry() } }
    }
    /// The height on screen of a document's tallest page, in page units.
    /// Worked out once per document, and only for a whole-page fit: it takes
    /// every page.
    private var tallestPage: TallestPage?

    private struct TallestPage {
        weak var document: PDFDocument?
        let height: CGFloat
    }
    /// Called after each change of geometry once the view has a size, which
    /// is when PDFKit starts to take jumps to a page.
    var onLayout: (() -> Void)?
    private var isCallingOnLayout = false
    private var isUpdatingGeometry = false
    private weak var observedClip: NSClipView?
    /// What's at the centre of the uncovered area, so it stays there when the
    /// sidebar opens or closes.
    private var centerAnchor: ZoomAnchor?
    /// Held from before the sidebar starts moving until it stops: PDFKit
    /// nudges the pages at each step, and re-anchoring would accumulate them.
    private var sidebarAnchor: ZoomAnchor?
    private var sidebarSettling: Task<Void, Never>?
    private var lastCoveredLeft: CGFloat?
    /// Page units per point when the scroll view last tiled.
    private var tiledUnit: CGFloat?
    var scrollMonitor: Any?
    /// Nil until the scroll under way has a direction.
    var pageScroll: PageScroll?
    var lastScrollTime: TimeInterval = 0
    /// The sidebar opening, closing or being resized changes only the safe
    /// area, which doesn't lay this view out again, so it's watched directly.
    private var safeAreaObservation: NSKeyValueObservation?
    var zoomAnimation: ZoomAnimation?

    // MARK: Geometry

    /// The part of the view that isn't under the sidebar or toolbar, or taken
    /// by a scroll bar.
    var uncoveredRect: CGRect {
        let covered = safeAreaInsets
        let clip =
            documentView?.enclosingScrollView?.contentView.frame ?? bounds
        return CGRect(
            x: covered.left, y: isFlipped ? covered.top : covered.bottom,
            width: max(1, clip.width - covered.left - covered.right),
            height: max(1, bounds.height - covered.top - covered.bottom))
    }

    func pageFrame(of page: PDFPage) -> PageFrame {
        PageFrame(box: page.bounds(for: displayBox), rotation: page.rotation)
    }

    func index(of page: PDFPage) -> Int? {
        document?.index(for: page)
    }

    /// The zoom at which the pages, with their usual margins, fit the
    /// uncovered area. The widest and the tallest page count, so the zoom is
    /// the same wherever the document is scrolled to.
    func fitScale(for fit: PageFit) -> CGFloat {
        guard let documentView else { return scaleFactor }
        let width = documentView.frame.width
        guard width > 0 else { return scaleFactor }
        let scale = fit.scale(
            width: width,
            height: tallestPageHeight() + verticalMargins(of: documentView),
            in: uncoveredRect.size)
        return scale.clamped(to: scaleRange)
    }

    var scaleRange: ClosedRange<CGFloat> { minScaleFactor...maxScaleFactor }

    /// The room a whole-page fit leaves above and below a page. Single Page
    /// and Two Pages hold only what's shown in the document view, so it
    /// tells how much. In the continuous layouts it's the margin the page is
    /// shown below (see `showTop`), and a page break's under it.
    private func verticalMargins(of documentView: NSView) -> CGFloat {
        guard [.singlePage, .twoUp].contains(displayMode), let currentPage
        else {
            return marginAboveFirstPage() / scaleFactor
                + pageBreakMargins.bottom
        }
        return documentView.frame.height
            - pageFrame(of: currentPage).shownSize.height
    }

    private func tallestPageHeight() -> CGFloat {
        guard let document else { return 0 }
        if let tallestPage, tallestPage.document === document {
            return tallestPage.height
        }
        let heights = (0..<document.pageCount).compactMap {
            document.page(at: $0).map { pageFrame(of: $0).shownSize.height }
        }
        let height = heights.max() ?? 0
        tallestPage = TallestPage(document: document, height: height)
        return height
    }

    /// Goes back to the fit's zoom when the uncovered area has changed.
    private func applyFit() {
        guard let fit else { return }
        let scale = fitScale(for: fit)
        if abs(scaleFactor - scale) > 0.0005 { scaleFactor = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard window != nil else { return cancelZoomAnimation() }
        safeAreaObservation = observe(\.safeAreaInsets) { view, _ in
            MainActor.assumeIsolated { view.updateGeometry() }
        }
        installScrollMonitor()
    }

    override func layout() {
        super.layout()
        if let documentView,
            let clip = documentView.enclosingScrollView?.contentView,
            observedClip !== clip
        {
            ClipConstraint.install(on: clip)
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            // The pages can also be re-arranged without the scroll position
            // changing.
            documentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.frameDidChangeNotification, object: documentView)
            observedClip = clip
        }
        geometryChanged()
    }

    @objc private func clipBoundsChanged() {
        geometryChanged()
    }

    private func geometryChanged() {
        updateGeometry()
        // Not from within itself: scrolling in it changes the geometry.
        guard let onLayout, !isCallingOnLayout,
            let clip = documentView?.enclosingScrollView?.contentView,
            clip.bounds.height > 0
        else { return }
        isCallingOnLayout = true
        defer { isCallingOnLayout = false }
        onLayout()
    }

    /// Keeps the insets and the fit in line with the
    /// sidebar, toolbar and zoom.
    func updateGeometry() {
        guard !isUpdatingGeometry,
            let scrollView = documentView?.enclosingScrollView
        else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }

        let covered = safeAreaInsets
        // When the sidebar opens or closes, what was at the centre moves to
        // the new centre.
        let sidebarChanged =
            lastCoveredLeft.map { abs($0 - covered.left) > 0.5 } ?? false
        if sidebarChanged { sidebarMoved() }
        let anchorToKeep = sidebarAnchor
        defer {
            lastCoveredLeft = covered.left
            centerAnchor = zoomAnchor()
        }
        if scrollView.automaticallyAdjustsContentInsets
            || abs(scrollView.contentInsets.top - covered.top) > 0.5
            || abs(scrollView.contentInsets.bottom - covered.bottom) > 0.5
            || abs(scrollView.contentInsets.left - covered.left) > 0.5
        {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: covered.top, left: covered.left, bottom: covered.bottom,
                right: 0)
        }
        applyFit()
        convertInsets(of: scrollView)
        if let anchorToKeep {
            restore(
                anchorToKeep,
                at: CGPoint(x: uncoveredRect.midX, y: uncoveredRect.midY))
        }
        centerIfNarrower()
    }

    /// The scroll view's left inset in the clip view's units.
    func leftInset(of scrollView: NSScrollView) -> CGFloat {
        scrollView.contentInsets.left
            * (scrollView.contentView.pageUnitsPerPoint ?? 0)
    }

    /// The clip view keeps the insets in page units, converted only when the
    /// scroll view tiles, which a change of zoom doesn't make it do.
    private func convertInsets(of scrollView: NSScrollView) {
        guard let unit = scrollView.contentView.pageUnitsPerPoint else {
            return
        }
        guard tiledUnit.map({ abs($0 - unit) > 0.0001 }) ?? true else {
            return
        }
        tiledUnit = unit
        scrollView.tile()
    }

    private func sidebarMoved() {
        if sidebarAnchor == nil { sidebarAnchor = centerAnchor }
        sidebarSettling?.cancel()
        sidebarSettling = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            sidebarAnchor = nil
            updateGeometry()
        }
    }

    /// Pages that fit beside the sidebar can't be scrolled sideways, so
    /// they're held in the middle of the uncovered area. PDFKit centres pages
    /// itself when it lays them out, but in the whole view.
    func centerIfNarrower() {
        guard let documentView,
            let scrollView = documentView.enclosingScrollView
        else { return }
        let clip = scrollView.contentView
        let pages = documentView.frame
        let inset = leftInset(of: scrollView)
        guard pages.width <= clip.bounds.width - inset + 0.5 else { return }
        let x = pages.midX - (clip.bounds.width + inset) / 2
        guard abs(clip.bounds.origin.x - x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
}

extension NSClipView {
    /// The clip view's bounds are in page units, its frame in points.
    var pageUnitsPerPoint: CGFloat? {
        frame.width > 0 && bounds.width > 0 ? bounds.width / frame.width : nil
    }
}
