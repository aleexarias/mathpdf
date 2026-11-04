import PDFKit

/// A PDFView that hands clicks, drags, Delete/Esc and right-clicks on mathpdf
/// annotations to the annotation editor, and pastes copied pages after the
/// page on screen. Everything else (text selection, links, scrolling) works
/// as usual.
final class AnnotationPDFView: PDFView {
    weak var editor: AnnotationEditor?
    weak var viewer: Viewer?

    private var drag: (page: PDFPage, start: CGPoint)?
    /// Set while PDFView handles a click or text selection that the active
    /// tool should use when it ends. Cleared once used, so a gesture is never
    /// used twice.
    private var toolGestureActive = false
    /// Delivers mouse moves, for the cursor over a text box's edge.
    private var mouseMovedTracking: NSTrackingArea?

    // The view reaches under the translucent toolbar and sidebar, so the pages
    // show through them, but it fits the pages to the uncovered area. PDFKit
    // handles a top inset well but not a left one, so the sidebar is allowed
    // for with extra left page margin instead: at the fit zoom it sits behind
    // the sidebar, and when zoomed in the pages can scroll clear of it.
    // Scrolling itself is left to PDFKit.

    /// While true, the pages are kept as wide as the uncovered area (Zoom to
    /// Fit).
    var fitsWidth = true {
        didSet { if fitsWidth { updateGeometry() } }
    }
    private var isUpdatingGeometry = false
    private weak var observedClip: NSClipView?
    /// What's at the centre of the uncovered area, so it stays there when the
    /// sidebar opens or closes.
    private var centerAnchor: ZoomAnchor?
    private var lastCoveredLeft: CGFloat?
    private var scrollMonitor: Any?
    /// The sidebar opening, closing or being resized changes only the safe
    /// area, which doesn't lay this view out again, so it's watched directly.
    private var safeAreaObservation: NSKeyValueObservation?
    private static let standardMargins = NSEdgeInsets(
        top: 4.75, left: 4, bottom: 4.75, right: 4)

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

    /// The zoom at which the pages, with their usual margins, exactly fill the
    /// uncovered width.
    var fitScale: CGFloat {
        guard let documentView else { return scaleFactor }
        let width =
            documentView.frame.width
            - (pageBreakMargins.left - Self.standardMargins.left)
        guard width > 0 else { return scaleFactor }
        return min(
            max(uncoveredRect.width / width, minScaleFactor), maxScaleFactor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        guard window != nil else { return }
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
        updateGeometry()
    }

    @objc private func clipBoundsChanged() {
        updateGeometry()
    }

    /// Keeps the left margin, the top inset and the fit in line with the
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
        let anchorToKeep = sidebarChanged ? centerAnchor : nil
        defer {
            lastCoveredLeft = covered.left
            centerAnchor = zoomAnchor()
        }
        if scrollView.automaticallyAdjustsContentInsets
            || abs(scrollView.contentInsets.top - covered.top) > 0.5
            || abs(scrollView.contentInsets.bottom - covered.bottom) > 0.5
            || scrollView.contentInsets.left != 0
        {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: covered.top, left: 0, bottom: covered.bottom, right: 0)
        }
        if fitsWidth, abs(scaleFactor - fitScale) > 0.0005 {
            scaleFactor = fitScale
        }
        // Page margins are in page units, so the sidebar's width in them
        // depends on the zoom.
        let left = Self.standardMargins.left + covered.left / scaleFactor
        if abs(pageBreakMargins.left - left) > 0.25 {
            var margins = Self.standardMargins
            margins.left = left
            pageBreakMargins = margins
            layoutDocumentView()  // so the centring below sees the new width
            if fitsWidth, abs(scaleFactor - fitScale) > 0.0005 {
                scaleFactor = fitScale
            }
        }
        if let anchorToKeep {
            restore(
                anchorToKeep,
                at: CGPoint(x: uncoveredRect.midX, y: uncoveredRect.midY))
        }
        centerIfNarrower()
    }

    /// When the pages (with the sidebar margin) are no wider than the view,
    /// they can't be scrolled sideways, so they're held centred, which puts
    /// them in the middle of the uncovered area. Wider pages are left entirely
    /// to the user.
    private func centerIfNarrower() {
        guard let documentView,
            let scrollView = documentView.enclosingScrollView
        else { return }
        let clip = scrollView.contentView
        let spare = clip.bounds.width - documentView.frame.width
        guard spare >= -0.5 else { return }
        let x = -max(0, spare) / 2
        guard abs(clip.bounds.origin.x - x) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Zoom

    /// Sets the zoom straight away, keeping what's at the centre of the
    /// uncovered area in place.
    func zoom(to scale: CGFloat) {
        fitsWidth = false
        let anchor = zoomAnchor()
        scaleFactor = min(max(scale, minScaleFactor), maxScaleFactor)
        updateGeometry()
        if let anchor { restore(anchor) }
    }

    /// Pinching zooms around the centre of the uncovered area.
    override func magnify(with event: NSEvent) {
        guard editor?.isEditingItem != true else { return }
        zoom(to: scaleFactor * (1 + event.magnification))
    }

    override func smartMagnify(with event: NSEvent) {
        guard editor?.isEditingItem != true else { return }
        fitsWidth = false
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
        let scale =
            clip.bounds.width > 0
            ? clip.frame.width / clip.bounds.width : scaleFactor
        let now = convert(anchor.pagePoint, from: anchor.page)
        var origin = clip.bounds.origin
        origin.x += (now.x - target.x) / scale
        origin.y +=
            (now.y - target.y) / scale
            * (documentView.isFlipped == isFlipped ? 1 : -1)
        // Never past the document's edges: that would hold only until the next
        // layout, then snap back. Pages narrower than the view are centred
        // instead (below).
        let wanted = NSRect(origin: origin, size: clip.bounds.size)
        let valid = clip.constrainBoundsRect(wanted).origin
        origin.y = valid.y
        if documentView.frame.width > clip.bounds.width { origin.x = valid.x }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        centerIfNarrower()
    }

    // MARK: Scrolling

    /// ⌘ + scroll zooms, and while a note or formula is being written,
    /// scrolling does nothing. Scroll events go to PDFView's inner scroll
    /// view, not to this view, so they're caught on their way to the window.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            // Scrolling away from the user zooms in, whatever the
            // natural-scrolling setting.
            let delta =
                event.isDirectionInvertedFromDevice
                ? -event.scrollingDeltaY : event.scrollingDeltaY
            let zoomStep =
                event.modifierFlags.contains(.command)
                // a mouse wheel reports lines
                ? (event.hasPreciseScrollingDeltas ? delta : delta * 8)
                : nil
            let windowNumber = event.windowNumber
            let location = event.locationInWindow
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window,
                    window.windowNumber == windowNumber,
                    self.bounds.contains(self.convert(location, from: nil))
                else { return false }
                if self.editor?.isEditingItem == true { return true }
                guard let zoomStep else { return false }
                self.zoom(to: self.scaleFactor * exp(zoomStep * 0.01))
                return true
            }
            return handled ? nil : event
        }
    }

    /// Scrolls as little as needed, if at all, to show `rect` on `page` clear
    /// of the toolbar, the sidebar and the window's edges. Something already
    /// in view doesn't move. If it's bigger than the view, its top-left corner
    /// is shown.
    func scrollToReveal(_ rect: CGRect, on page: PDFPage, margin: CGFloat = 12)
    {
        let shown = convert(rect, from: page)
        let area = uncoveredRect.insetBy(dx: margin, dy: margin)
        func shift(
            _ low: CGFloat, _ high: CGFloat, within areaLow: CGFloat,
            _ areaHigh: CGFloat, keepingLow: Bool
        ) -> CGFloat {
            if high - low > areaHigh - areaLow {
                return keepingLow ? areaLow - low : areaHigh - high
            }
            if low < areaLow { return areaLow - low }
            if high > areaHigh { return areaHigh - high }
            return 0
        }
        let dx = shift(
            shown.minX, shown.maxX, within: area.minX, area.maxX,
            keepingLow: true)
        let dy = shift(
            shown.minY, shown.maxY, within: area.minY, area.maxY,
            keepingLow: isFlipped)  // the top
        guard dx != 0 || dy != 0 else { return }
        let center = CGPoint(x: shown.midX, y: shown.midY)
        restore(
            ZoomAnchor(
                page: page, pagePoint: convert(center, to: page),
                viewPoint: center),
            at: CGPoint(x: center.x + dx, y: center.y + dy))
    }

    // MARK: Mouse and keyboard

    override func mouseDown(with event: NSEvent) {
        guard let editor, let (page, point) = location(of: event),
            editor.mouseDown(
                on: page, at: point, clickCount: event.clickCount,
                timestamp: event.timestamp)
        else {
            toolGestureActive = true
            super.mouseDown(with: event)
            // If PDFView tracked the whole click or selection itself, the
            // mouse is already up; the mouse-up it handled says where.
            if NSEvent.pressedMouseButtons & 1 == 0, let window {
                let mouseUp = NSApp.currentEvent.flatMap {
                    $0.type == .leftMouseUp ? $0 : nil
                }
                finishToolGesture(
                    at: location(
                        inWindow: mouseUp?.locationInWindow
                            ?? window.mouseLocationOutsideOfEventStream))
            }
            return
        }
        window?.makeFirstResponder(self)
        drag = (page, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return super.mouseDragged(with: event) }
        editor?.dragMoved(by: offset(of: event, from: drag))
        if editor?.isSettingWidth == true { NSCursor.resizeLeftRight.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let (page, point) = location(of: event),
            editor?.isOnTextBoxEdge(point, on: page) == true
        {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if mouseMovedTracking == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            mouseMovedTracking = area
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else {
            super.mouseUp(with: event)
            finishToolGesture(at: location(of: event))
            return
        }
        self.drag = nil
        editor?.mouseUp(movedBy: offset(of: event, from: drag))
    }

    override func keyDown(with event: NSEvent) {
        let handled: Bool
        switch event.specialKey {
        case .delete?, .deleteForward?:
            handled = editor?.deleteSelection() ?? false
        // Esc
        default: handled = event.keyCode == 53 && editor?.cancel() == true
        }
        if !handled { super.keyDown(with: event) }
    }

    /// Only pages copied in mathpdf: a PDF from another app is more likely a
    /// snippet than pages.
    @objc func paste(_ sender: Any?) {
        guard let viewer else { return }
        Task {
            await viewer.pasteFromClipboard(
                at: viewer.pageIndex + 1, fromOtherApps: false)
        }
    }

    /// Takes Paste only while there are pages to paste. PDFView enables any
    /// menu item it's asked about, and its validation can't be extended from
    /// Swift.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(paste(_:)) {
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                viewer?.canPastePages(fromOtherApps: false) == true
            }
        }
        return super.responds(to: selector)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let (page, point) = location(of: event),
            let menu = editor?.contextMenu(on: page, at: point)
        {
            return menu
        }
        return super.menu(for: event)
    }

    /// A click or text selection finished: let the active tool use it, once.
    private func finishToolGesture(
        at location: (page: PDFPage, point: CGPoint)?
    ) {
        guard toolGestureActive else { return }
        toolGestureActive = false
        editor?.useTool(at: location)
    }

    private func location(of event: NSEvent) -> (
        page: PDFPage, point: CGPoint
    )? {
        location(inWindow: event.locationInWindow)
    }

    private func location(inWindow windowPoint: NSPoint) -> (
        page: PDFPage, point: CGPoint
    )? {
        let viewPoint = convert(windowPoint, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }
        return (page, convert(viewPoint, to: page))
    }

    private func offset(
        of event: NSEvent, from drag: (page: PDFPage, start: CGPoint)
    ) -> CGSize {
        let point = convert(
            convert(event.locationInWindow, from: nil), to: drag.page)
        return CGSize(
            width: point.x - drag.start.x, height: point.y - drag.start.y)
    }

    // MARK: Formula layers

    /// PDFKit draws each custom-drawn annotation (a formula) in a layer of its
    /// own and doesn't take that layer away when the annotation leaves its
    /// page, so moved, edited and deleted formulas would stay on screen as
    /// ghosts. This removes the layers of annotations that are no longer on a
    /// page. The layers are PDFKit internals: every step is checked, and if
    /// they change this does nothing.
    func removeLayersOfRemovedAnnotations() {
        let annotationSelector = NSSelectorFromString("annotation")
        let idSelector = NSSelectorFromString("UUID")
        let removeSelector = NSSelectorFromString(
            "removePageLayerEffectForID:")
        func visit(_ layer: CALayer, pageLayer: CALayer?) {
            let pageLayer =
                layer.responds(to: removeSelector) ? layer : pageLayer
            for sublayer in layer.sublayers ?? [] {
                visit(sublayer, pageLayer: pageLayer)
            }
            guard
                NSStringFromClass(Swift.type(of: layer)).hasSuffix(
                    "AnnotationEffect"),
                layer.responds(to: annotationSelector),
                let annotation = layer.perform(annotationSelector)?
                    .takeUnretainedValue() as? PDFAnnotation,
                annotation.page == nil
            else { return }
            // Through the page layer, so PDFKit forgets the layer too.
            if let pageLayer, layer.responds(to: idSelector),
                let id = layer.perform(idSelector)?.takeUnretainedValue()
            {
                pageLayer.perform(removeSelector, with: id)
            }
            if layer.superlayer != nil { layer.removeFromSuperlayer() }
        }
        if let layer { visit(layer, pageLayer: nil) }
    }
}
