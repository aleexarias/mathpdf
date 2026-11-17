import PDFKit

extension AnnotationPDFView {
    /// ⌘ + scroll zooms, and while a note or formula is being written,
    /// scrolling does nothing. Scroll events go to PDFView's inner scroll
    /// view, not to this view, so they're caught on their way to the window.
    func installScrollMonitor() {
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
            deltaX = event.scrollingDeltaX * event.scrollingPointsPerUnit
            deltaY = event.scrollingDeltaY * event.scrollingPointsPerUnit
            time = event.timestamp
            begins = event.phase.contains(.began)
            isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
        }
    }

    enum PageScroll { case withinPage, turned }

    /// In Single Page and Two Pages, PDFKit turns a page for every event that
    /// runs past the end. Instead, a scroll that starts short of the end
    /// stops there, and one that starts at the end turns one page. Every
    /// event is handled here: once the scroll view gets a gesture's first
    /// event, it takes the rest directly, bypassing this monitor.
    private func scrollWithinPage(_ scroll: Scroll) -> Bool {
        guard [.singlePage, .twoUp].contains(displayMode),
            let scrollView = documentView?.enclosingScrollView,
            let unit = scrollView.contentView.pageUnitsPerPoint
        else { return false }
        // A wheel's scroll ends at a pause.
        if scroll.begins
            || (scroll.isWheel && scroll.time - lastScrollTime > 0.3)
        {
            pageScroll = nil
        }
        lastScrollTime = scroll.time
        let clip = scrollView.contentView
        let dy = scroll.deltaY * unit * (clip.isFlipped ? -1 : 1)
        if pageScroll == nil, abs(scroll.deltaY) > abs(scroll.deltaX) {
            if room(towardsHigh: dy > 0, in: scrollView) > 0.5 {
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
        let clip = scrollView.contentView
        guard let range = scrollLimits(of: scrollView).y else { return }
        let y = up == clip.isFlipped ? range.upperBound : range.lowerBound
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the top of `page` to the top of the uncovered area, as far
    /// below it as the first page is at the top of the document. PDFKit's
    /// `go(to:)` does too, but in two-page layouts it ignores the toolbar.
    func showTop(of page: PDFPage) {
        let shown = convert(page.bounds(for: displayBox), from: page)
        let top = CGPoint(
            x: shown.midX, y: isFlipped ? shown.minY : shown.maxY)
        let margin = marginAboveFirstPage()
        let area = uncoveredRect
        restore(
            ZoomAnchor(
                page: page, pagePoint: convert(top, to: page), viewPoint: top),
            at: CGPoint(
                x: top.x,
                y: isFlipped ? area.minY + margin : area.maxY - margin))
    }

    /// Single Page Continuous leaves one page break margin above the first
    /// page, the other layouts two.
    func marginAboveFirstPage() -> CGFloat {
        guard let documentView, let first = document?.page(at: 0) else {
            return 0
        }
        let pages = convert(documentView.bounds, from: documentView)
        let page = convert(first.bounds(for: displayBox), from: first)
        return isFlipped ? page.minY - pages.minY : pages.maxY - page.maxY
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

    /// After PDFKit's `go(to:)`, which in two-page layouts can leave what it
    /// went to under the toolbar.
    func keepInView(_ rect: CGRect, on page: PDFPage) {
        layoutDocumentView()
        scrollToReveal(rect, on: page)
    }
}

extension NSEvent {
    /// A mouse wheel reports lines, a trackpad points.
    var scrollingPointsPerUnit: CGFloat { hasPreciseScrollingDeltas ? 1 : 10 }
}
