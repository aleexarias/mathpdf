import MathPDFCore
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
    private var scrollMonitor: Any?
    /// Nil until the scroll under way has a direction.
    private var pageScroll: PageScroll?
    private var lastScrollTime: TimeInterval = 0
    /// The sidebar opening, closing or being resized changes only the safe
    /// area, which doesn't lay this view out again, so it's watched directly.
    private var safeAreaObservation: NSKeyValueObservation?

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

    /// The zoom at which the pages, with their usual margins, fit the
    /// uncovered area. The widest and the tallest page count, so the zoom is
    /// the same wherever the document is scrolled to.
    func fitScale(for fit: PageFit) -> CGFloat {
        guard let documentView else { return scaleFactor }
        let margins = pageBreakMargins
        let width = documentView.frame.width
        guard width > 0 else { return scaleFactor }
        let scale = fit.scale(
            width: width,
            height: tallestPageHeight() + margins.top + margins.bottom,
            in: uncoveredRect.size)
        return min(max(scale, minScaleFactor), maxScaleFactor)
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
        if let anchorToKeep {
            restore(
                anchorToKeep,
                at: CGPoint(x: uncoveredRect.midX, y: uncoveredRect.midY))
        }
        centerIfNarrower()
    }

    /// The scroll view's left inset in the clip view's units.
    private func leftInset(of scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        guard clip.frame.width > 0 else { return 0 }
        return scrollView.contentInsets.left * clip.bounds.width
            / clip.frame.width
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
    private func centerIfNarrower() {
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

    // MARK: Zoom

    /// Sets the zoom straight away, keeping what's at the centre of the
    /// uncovered area in place.
    func zoom(to scale: CGFloat) {
        fit = nil
        let anchor = zoomAnchor()
        scaleFactor = min(max(scale, minScaleFactor), maxScaleFactor)
        updateGeometry()
        if let anchor { restore(anchor) }
    }

    private struct ZoomAnimation {
        let link: CADisplayLink
        let anchor: ZoomAnchor?
        let start: CGFloat
        let end: CGFloat
        let began: CFTimeInterval
        let completion: (() -> Void)?
    }
    private var zoomAnimation: ZoomAnimation?
    private static let zoomDuration: CFTimeInterval = 0.32

    /// Eases the zoom to `target`, around the centre of the uncovered area.
    /// It moves evenly on a log scale, so zooming in and out feel the same,
    /// and a step is taken for each frame the display shows: a timer drifts
    /// against the display and stutters.
    func animateZoom(to target: CGFloat, then completion: (() -> Void)? = nil)
    {
        cancelZoomAnimation()
        fit = nil
        let end = min(max(target, minScaleFactor), maxScaleFactor)
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
        // layout, then snap back.
        origin = clamped(origin, in: scrollView)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        centerIfNarrower()
    }

    /// Avoids `constrainBoundsRect`, which in two-page layouts also moves
    /// positions well inside the document. Where the document fits, PDFKit's
    /// own position is kept, as it centres the pages there.
    private func clamped(
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
    private func scrollLimits(
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
        // Insets are in points, the clip view's bounds in page units.
        let unit = clip.bounds.width / clip.frame.width
        let top = scrollView.contentInsets.top * unit
        let bottom = scrollView.contentInsets.bottom * unit
        let (low, high) = clip.isFlipped ? (top, bottom) : (bottom, top)
        return (
            limits(
                document.minX - leftInset(of: scrollView),
                document.maxX - clip.bounds.width),
            limits(
                document.minY - low,
                document.maxY - clip.bounds.height + high)
        )
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
            let scroll = Scroll(event)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window,
                    window.windowNumber == windowNumber,
                    self.bounds.contains(self.convert(location, from: nil))
                else { return false }
                if self.editor?.isEditingItem == true { return true }
                guard let zoomStep else {
                    return self.scrollWithinPage(scroll)
                }
                self.zoom(to: self.scaleFactor * exp(zoomStep * 0.01))
                return true
            }
            return handled ? nil : event
        }
    }

    /// The parts of a scroll event used on the main actor, which the
    /// non-Sendable event can't be taken into.
    private struct Scroll {
        /// In points, positive towards the top and left of the document.
        let deltaX: CGFloat
        let deltaY: CGFloat
        let time: TimeInterval
        let begins: Bool
        /// Trackpad events have a gesture or momentum phase; a wheel's don't.
        let isWheel: Bool

        init(_ event: NSEvent) {
            // A wheel reports lines.
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            deltaX = event.scrollingDeltaX * unit
            deltaY = event.scrollingDeltaY * unit
            time = event.timestamp
            begins = event.phase.contains(.began)
            isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        }
    }

    private enum PageScroll { case withinPage, turned }

    /// In Single Page and Two Pages, PDFKit turns a page for every event that
    /// runs past the end. Instead, a scroll that starts short of the end
    /// stops there, and one that starts at the end turns one page. Every
    /// event is handled here: once the scroll view gets a gesture's first
    /// event, it takes the rest directly, bypassing this monitor.
    private func scrollWithinPage(_ scroll: Scroll) -> Bool {
        guard [.singlePage, .twoUp].contains(displayMode),
            let scrollView = documentView?.enclosingScrollView,
            scrollView.contentView.frame.width > 0
        else { return false }
        // A wheel's scroll ends at a pause.
        if scroll.begins
            || (scroll.isWheel && scroll.time - lastScrollTime > 0.3)
        {
            pageScroll = nil
        }
        lastScrollTime = scroll.time
        let clip = scrollView.contentView
        let unit = clip.bounds.width / clip.frame.width
        let dy = scroll.deltaY * unit * (clip.isFlipped ? -1 : 1)
        if pageScroll == nil, abs(scroll.deltaY) > abs(scroll.deltaX) {
            // At a whole-page fit only the margin is left to scroll.
            let margin = pageBreakMargins.top + pageBreakMargins.bottom
            if room(towardsHigh: dy > 0, in: scrollView) > margin + 0.5 {
                pageScroll = .withinPage
            } else {
                pageScroll = .turned
                turnPage(up: scroll.deltaY > 0, in: scrollView)
            }
        }
        guard pageScroll != .turned else { return true }
        let origin = NSPoint(
            x: clip.bounds.origin.x - scroll.deltaX * unit,
            y: clip.bounds.origin.y + dy)
        clip.scroll(to: clamped(origin, in: scrollView))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    private func room(
        towardsHigh: Bool, in scrollView: NSScrollView
    ) -> CGFloat {
        guard let range = scrollLimits(of: scrollView).y else { return 0 }
        let y = scrollView.contentView.bounds.origin.y
        return towardsHigh ? range.upperBound - y : y - range.lowerBound
    }

    /// Shows the top of the next page, or the bottom of the previous one.
    private func turnPage(up: Bool, in scrollView: NSScrollView) {
        guard let viewer else { return }
        let before = viewer.pageIndex
        viewer.turnPage(by: up ? -1 : 1)
        guard viewer.pageIndex != before else { return }
        layoutDocumentView()
        let clip = scrollView.contentView
        guard let range = scrollLimits(of: scrollView).y else { return }
        let y = up == clip.isFlipped ? range.upperBound : range.lowerBound
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the top of `page` to the top of the uncovered area. PDFKit's
    /// `go(to:)` does too, but in two-page layouts it ignores the toolbar.
    func showTop(of page: PDFPage) {
        let shown = convert(page.bounds(for: displayBox), from: page)
        let top = CGPoint(
            x: shown.midX, y: isFlipped ? shown.minY : shown.maxY)
        let margin = pageBreakMargins.top * scaleFactor
        let area = uncoveredRect
        restore(
            ZoomAnchor(
                page: page, pagePoint: convert(top, to: page), viewPoint: top),
            at: CGPoint(
                x: top.x,
                y: isFlipped ? area.minY + margin : area.maxY - margin))
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

    /// PDFKit only updates the pointer when what's under it changes, so an
    /// I-beam left by a text field would persist over a formula or text box.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let editor, let (page, point) = location(of: event) else {
            return
        }
        if editor.isOnTextBoxEdge(point, on: page) {
            NSCursor.resizeLeftRight.set()
        } else if editor.isOnBox(point, on: page) {
            NSCursor.arrow.set()
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
        // Arrow keys also carry flags that aren't modifiers.
        let modifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        switch event.specialKey {
        case .delete?, .deleteForward?:
            handled = editor?.deleteSelection() ?? false
        case let key?
        where (key == .leftArrow || key == .rightArrow) && modifiers.isEmpty:
            viewer?.turnPage(by: key == .leftArrow ? -1 : 1)
            handled = true
        // Backs up the menu's ⌥⇥ and ⌥⇧⇥: ⇧⇥ arrives as back-tab, which a
        // Tab key equivalent may not match.
        case let key?
        where (key == .tab || key == .backTab)
            && modifiers.subtracting(.shift) == .option:
            editor?.cycleColor(backwards: modifiers.contains(.shift))
            handled = true
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

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
