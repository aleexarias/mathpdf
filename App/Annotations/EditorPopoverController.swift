import AppKit
import MathPDFCore
import MathPDFLaTeX
import MathPDFRendering
import PDFKit
import SwiftUI

/// The popover where a note's text or a formula's source is written, and the
/// rules for leaving it. One per window.
@MainActor
final class EditorPopoverController: NSObject {
    /// The size new formulas get: the last one chosen.
    private(set) var latexFontSize: Double = 16
    /// The size new text boxes get: the last one chosen.
    private(set) var textFontSize: Double = 14

    private let session: DocumentSession
    private let pdfView: AnnotationPDFView
    private var current: OpenEditor?
    /// While an editor is open, Esc tries to finish it, whichever view has
    /// focus: before Esc can turn the tool off, and instead of the text view's
    /// word completions. Mouse downs are noted too (see `currentAttempt`).
    private var eventMonitor: Any?
    private var lastMouseDown: TimeInterval?
    /// The event that closed an editor. A click on the page that closes it
    /// shouldn't also add a new note or formula.
    private var closingEvent: TimeInterval?

    private static let watchedEvents: NSEvent.EventTypeMask = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    private struct OpenEditor {
        let id: UUID
        let isNew: Bool
        let draft: Draft
        let popover: NSPopover
    }

    private enum Draft {
        case note(NoteDraft)
        case latex(LaTeXDraft)
        case textBox(TextBoxDraft)
    }

    init(session: DocumentSession, pdfView: AnnotationPDFView) {
        self.session = session
        self.pdfView = pdfView
    }

    var isOpen: Bool { current != nil }

    func closed(by timestamp: TimeInterval) -> Bool {
        timestamp == closingEvent
    }

    func editNote(_ id: UUID, isNew: Bool) {
        // an editor still open keeps what was typed
        guard tryToFinish() else { return }
        guard let note = annotation(id), case .note(let text, _) = note.kind
        else { return }
        let draft = NoteDraft(text: text)
        present(
            NoteEditorView(draft: draft) { [weak self] in
                self?.tryToFinish()
            },
            for: note, isNew: isNew, draft: .note(draft))
    }

    func editLaTeX(_ id: UUID, isNew: Bool) {
        guard tryToFinish() else { return }
        guard let formula = annotation(id),
            case .latex(let source, let fontSize, let expanded) = formula.kind
        else { return }
        let draft = LaTeXDraft(
            source: source, fontSize: fontSize, expanded: expanded)
        present(
            LaTeXEditorView(draft: draft) { [weak self] in
                self?.tryToFinish()
            },
            for: formula, isNew: isNew, draft: .latex(draft))
    }

    func editTextBox(_ id: UUID, isNew: Bool) {
        guard tryToFinish() else { return }
        guard let box = annotation(id),
            case .textBox(let text, let fontSize) = box.kind
        else { return }
        let draft = TextBoxDraft(text: text, fontSize: fontSize)
        present(
            TextBoxEditorView(draft: draft) { [weak self] in
                self?.tryToFinish()
            }, for: box, isNew: isNew,
            draft: .textBox(draft))
    }

    /// One try to leave the editor: Esc, Done (⌘↩) or a click outside it.
    /// Returns whether it closed. If a formula has an error, the first try
    /// shows the error and keeps the editor open; another try with nothing
    /// changed deletes a new formula, or discards the change to an existing
    /// one. After any change, the next try checks it afresh.
    @discardableResult
    func tryToFinish(closingPopover: Bool = true) -> Bool {
        guard let current else {
            removeEventMonitor()
            return true
        }
        if case .latex(let draft) = current.draft {
            let attempt = currentAttempt
            if let attempt, attempt == draft.lastAttempt { return false }
            draft.lastAttempt = attempt
            if let error = formulaError(in: current.draft) {
                if draft.isErrorCurrent {
                    end(saving: false, closingPopover: closingPopover)
                    return true
                }
                draft.show(error: error)
                session.select(current.id)
                return false
            }
        }
        end(saving: true, closingPopover: closingPopover)
        return true
    }

    /// Closes the editor without asking, e.g. before the window closes. What
    /// was typed is saved, except a formula with an error: a new one is
    /// deleted, an existing one left as it was.
    func close() {
        guard let current else { return removeEventMonitor() }
        end(saving: formulaError(in: current.draft) == nil)
    }

    // MARK: Showing and ending

    private func present(
        _ content: some View, for annotation: Annotation, isNew: Bool,
        draft: Draft
    ) {
        guard let page = pdfView.document?.page(at: annotation.pageIndex)
        else { return }
        pdfView.scrollToReveal(annotation.bounds, on: page)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = EditorPopoverHost.controller(
            for: content)
        current = OpenEditor(
            id: annotation.id, isNew: isNew, draft: draft, popover: popover)
        popover.show(
            relativeTo: pdfView.convert(annotation.bounds, from: page),
            of: pdfView, preferredEdge: .maxY)
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: Self.watchedEvents
        ) { [weak self] event in
            let type = event.type, timestamp = event.timestamp
            // keyCode and isARepeat are only valid for key events: reading
            // them from a mouse event makes AppKit drop that event.
            let isEsc = type == .keyDown && event.keyCode == 53
            let isRepeat = type == .keyDown && event.isARepeat
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.current != nil else { return false }
                guard type == .keyDown else {
                    self.lastMouseDown = timestamp
                    return false
                }
                guard isEsc else { return false }
                // holding Esc down doesn't give up on a formula
                if !isRepeat { self.tryToFinish() }
                return true
            }
            return handled ? nil : event
        }
    }

    /// Which key press or click is trying to finish. A click counts once: the
    /// page gets its mouse down, and the popover asks to close on its mouse
    /// up.
    private var currentAttempt: TimeInterval? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return lastMouseDown ?? event.timestamp
        default: return event.timestamp
        }
    }

    private func formulaError(in draft: Draft) -> String? {
        guard case .latex(let draft) = draft else { return nil }
        do {
            let expanded = try draft.expansion(
                using: Persistence.latexCommands.current)
            guard
                case .invalid(let message) = LaTeXRenderer.typeset(
                    expanded, fontSize: draft.fontSize, color: .black)
            else { return nil }
            return message
        } catch {
            return error.message
        }
    }

    /// Saves what's in the editor right away; the popover's closing animation
    /// doesn't delay it. Not saving only applies to formulas: a new one is
    /// deleted, an existing one unchanged.
    private func end(saving: Bool, closingPopover: Bool = true) {
        guard let current else { return }
        removeEventMonitor()
        self.current = nil
        closingEvent = NSApp.currentEvent?.timestamp
        switch current.draft {
        case .note(let draft):
            session.finishNote(
                current.id, text: draft.text, isNew: current.isNew)
        case .latex(let draft) where saving:
            latexFontSize = draft.fontSize
            let expanded =
                (try? draft.expansion(
                    using: Persistence.latexCommands.current)) ?? draft.source
            session.finishLaTeX(
                current.id, source: draft.source, expanded: expanded,
                fontSize: draft.fontSize,
                size: LaTeXRenderer.size(
                    of: expanded, fontSize: draft.fontSize),
                isNew: current.isNew, within: pageFrame(of: current.id))
        case .textBox(let draft):
            textFontSize = draft.fontSize
            session.finishTextBox(
                current.id, text: draft.text, fontSize: draft.fontSize,
                size: textBoxSize(
                    of: draft, id: current.id, isNew: current.isNew),
                isNew: current.isNew, within: pageFrame(of: current.id))
        case .latex(let draft):
            if current.isNew {  // empty: removed
                session.finishLaTeX(
                    current.id, source: "", fontSize: draft.fontSize,
                    size: .zero, isNew: true)
            }
        }
        if closingPopover, current.popover.isShown { current.popover.close() }
    }

    /// A new text box is as wide as its longest line, up to the page's width
    /// less half-inch margins. An existing one keeps its width, which only
    /// dragging its edge changes, and its text wraps to it. All as seen on
    /// screen.
    private func textBoxSize(of draft: TextBoxDraft, id: UUID, isNew: Bool)
        -> CGSize
    {
        let frame = pageFrame(of: id)
        if !isNew, let size = annotation(id)?.bounds.size {
            return TextBoxStyle.size(
                of: draft.text, fontSize: draft.fontSize,
                width: frame?.turned(size).width ?? size.width)
        }
        let widest = max(
            TextBoxStyle.minimumWidth(fontSize: draft.fontSize),
            (frame?.shownSize.width ?? 612) - 72)
        return TextBoxStyle.size(
            of: draft.text, fontSize: draft.fontSize, maxWidth: widest)
    }

    /// The page an annotation is on, as shown, so a formula or text box that
    /// grows stays on it.
    private func pageFrame(of id: UUID) -> PageFrame? {
        guard let annotation = annotation(id),
            let page = pdfView.document?.page(at: annotation.pageIndex)
        else { return nil }
        return pdfView.pageFrame(of: page)
    }

    private func annotation(_ id: UUID) -> Annotation? {
        session.annotations.first { $0.id == id }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

extension EditorPopoverController: NSPopoverDelegate {
    /// A click outside the editor is a try to leave it, like Esc: a formula
    /// with an error keeps it open the first time. Switching to another app
    /// doesn't count.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let current, popover === current.popover else { return true }
        if !NSApp.isActive, formulaError(in: current.draft) != nil {
            return false
        }
        return tryToFinish(closingPopover: false)
    }

    /// SwiftUI gives the text the keyboard, but the caret isn't placed until
    /// something moves it, so it would stay invisible until the first
    /// keystroke. Putting it at the end shows it.
    func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
            popover === current?.popover,
            let content = popover.contentViewController?.view,
            let window = content.window,
            let textView = Self.textView(in: content)
        else { return }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0))
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap(textView(in:)).first
    }

    /// If the popover closes some other way, what was typed is saved as soon
    /// as it starts closing.
    func popoverWillClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover,
            popover === current?.popover
        else { return }
        close()
    }
}
