import Carbon.HIToolbox
import PDFKit

extension AnnotationPDFView {
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
        editor?.gestureCursor?.set()
    }

    /// PDFKit only updates the pointer when what's under it changes, so an
    /// I-beam left by a text field would persist over a formula or text box.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let editor, let (page, point) = location(of: event) else {
            return
        }
        editor.cursor(at: point, on: page)?.set()
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
        where (key == .carriageReturn || key == .enter) && modifiers.isEmpty:
            handled = editor?.toggleCropping() ?? false
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
        default:
            handled =
                Int(event.keyCode) == kVK_Escape && editor?.cancel() == true
        }
        if !handled { super.keyDown(with: event) }
    }

    /// Pages copied in mathpdf, or else an image. A PDF from another app is
    /// more likely a snippet than pages.
    @objc func paste(_ sender: Any?) {
        guard let viewer else { return }
        guard viewer.canPastePages(fromOtherApps: false) else {
            return viewer.editor.pasteImage()
        }
        viewer.pasteFromClipboard(
            at: viewer.pageIndex + 1, fromOtherApps: false)
    }

    /// Takes Paste only while there are pages or an image to paste. PDFView
    /// enables any menu item it's asked about, and its validation can't be
    /// extended from Swift.
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(paste(_:)) {
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                guard let viewer else { return false }
                return viewer.canPastePages(fromOtherApps: false)
                    || viewer.editor.canPasteImage
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
}
