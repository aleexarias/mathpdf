import AppKit
import MathPDFCore
import MathPDFLaTeX
import MathPDFRendering
import Observation
import PDFKit

/// Turns clicks, drags and toolbar actions into changes to the session. The
/// pages are drawn by `AnnotationRenderer`; notes and formulas are written in
/// `EditorPopoverController`. One per window.
@MainActor @Observable
final class AnnotationEditor: NSObject {
    /// Tools stay on until turned off. With the highlighter or underliner on,
    /// selecting text marks it; with the note tool on, selecting text (or
    /// clicking a word) attaches a note; with the LaTeX or text tool on, a
    /// click places a formula or a text box there.
    enum Tool {
        case highlight, underline, note, latex, text

        var name: String {
            switch self {
            case .highlight: "Highlight"
            case .underline: "Underline"
            case .note: "Note"
            case .latex: "LaTeX"
            case .text: "Text"
            }
        }

        var placesByClick: Bool { self == .latex || self == .text }
    }

    private(set) var tool: Tool?
    private(set) var highlightColor = Palette.yellow
    private(set) var underlineColor = Palette.red
    private(set) var hasTextSelection = false
    func renderVersion(ofPage index: Int) -> Int {
        renderer.pageVersions[index] ?? 0
    }

    @ObservationIgnored private let session: DocumentSession
    @ObservationIgnored private let pdfView: AnnotationPDFView
    @ObservationIgnored private let renderer: AnnotationRenderer
    @ObservationIgnored private let popover: EditorPopoverController
    @ObservationIgnored private var gesture: Gesture?
    /// The page text under each highlight and underline, for the sidebar. They
    /// can't move, so the text is looked up once.
    @ObservationIgnored private var textUnder: [UUID: String] = [:]
    /// The note or formula a double-click will open for editing when the click
    /// ends.
    @ObservationIgnored private var editOnMouseUp: Annotation?

    private static let noteSize: CGFloat = 15

    private enum Gesture {
        case move(Move)
        case setWidth(WidthChange)
    }

    /// An item being dragged: its marks where they started, and how far each
    /// way it can move without leaving its page.
    private struct Move {
        let itemID: UUID
        let origins: [(mark: PDFAnnotation, bounds: CGRect)]
        let limits: CGRect

        func clamped(_ offset: CGSize) -> CGSize {
            CGSize(
                width: min(max(offset.width, limits.minX), limits.maxX),
                height: min(max(offset.height, limits.minY), limits.maxY))
        }
    }

    /// A text box's width being set by dragging its right edge: the text wraps
    /// to it, the height follows, and the top-left corner stays put.
    private struct WidthChange {
        let id: UUID
        let mark: PDFAnnotation
        let start: CGRect
        let text: String
        let fontSize: Double
        /// From the narrowest a box can be to the page's right edge.
        let widths: ClosedRange<CGFloat>
        let page: CGRect

        func bounds(movedBy dx: CGFloat) -> CGRect {
            let width = min(
                max(start.width + dx, widths.lowerBound), widths.upperBound)
            let size = TextBoxStyle.size(
                of: text, fontSize: fontSize, width: width)
            return CGRect(
                x: start.minX, y: start.maxY - size.height, width: size.width,
                height: size.height)
        }
    }

    init(session: DocumentSession, pdfView: AnnotationPDFView) {
        self.session = session
        self.pdfView = pdfView
        renderer = AnnotationRenderer(session: session, pdfView: pdfView)
        popover = EditorPopoverController(session: session, pdfView: pdfView)
        super.init()
        pdfView.editor = self
        session.undoManagerProvider = { [weak self] in
            self?.windowUndoManager()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(textSelectionChanged),
            name: .PDFViewSelectionChanged, object: pdfView)
    }

    /// The window's own undo manager. The read-only document's undo manager is
    /// switched off first: edits recorded there make macOS try (and fail) to
    /// autosave the PDF.
    func windowUndoManager() -> UndoManager? {
        guard let window = pdfView.window else { return nil }
        if let document = NSDocumentController.shared.document(for: window),
            document.hasUndoManager
        {
            document.hasUndoManager = false
        }
        return window.undoManager
    }

    /// While a note or formula is being written the page stays put, so it
    /// stays under its editor.
    var isEditingItem: Bool { popover.isOpen }

    /// Finishes an open note or formula editor, as a click elsewhere would.
    /// False if it stays open because the formula has an error, which is then
    /// shown.
    func finishEditing() -> Bool {
        popover.tryToFinish()
    }

    func closeEditor() {
        popover.close()
    }

    @objc private func textSelectionChanged() {
        hasTextSelection = pdfView.currentSelection?.string?.isEmpty == false
        renderer.textSelectionChanged()
    }

    // MARK: Toolbar and menu actions

    /// With text selected, applies the tool to it once and leaves no tool on.
    /// Otherwise turns the tool on, or off if it's already on.
    func toggleTool(_ newTool: Tool) {
        guard session.canEdit else { return NSSound.beep() }
        // a formula with an error is shown first
        guard popover.tryToFinish() else { return }
        if hasTextSelection, !newTool.placesByClick {
            tool = nil
            // uses the selection before deselecting can clear it
            apply(newTool)
            session.select(nil)
            return
        }
        tool = tool == newTool ? nil : newTool
        session.select(nil)
    }

    private func apply(_ tool: Tool) {
        switch tool {
        case .highlight: addMarkup(.highlight, color: highlightColor)
        case .underline: addMarkup(.underline, color: underlineColor)
        case .note: addNoteToSelection()
        case .latex, .text: break
        }
    }

    /// Called when the mouse goes up after a click or text selection on the
    /// page, with where.
    func useTool(at location: (page: PDFPage, point: CGPoint)?) {
        guard let tool, session.canEdit else { return }
        if !hasTextSelection, let (page, point) = location,
            let document = pdfView.document,
            let hit = session.annotations.annotation(
                at: point, pageIndex: document.index(for: page))
        {
            session.select(hit.itemID)
            return
        }
        // Notes always belong to text: the selection, or the word that was
        // clicked.
        if tool == .note, !hasTextSelection, let (page, point) = location,
            let word = page.selectionForWord(at: point),
            word.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false,
            word.bounds(for: page).insetBy(dx: -2, dy: -2).contains(point)
        {
            pdfView.setCurrentSelection(word, animate: false)
        }
        if tool.placesByClick {
            if !hasTextSelection, let (page, point) = location {
                place(tool, on: page, at: point)
            }
            return
        }
        if hasTextSelection { apply(tool) }
    }

    /// The Colour menu: the colour of the brush that's on, or else of the
    /// selected annotation. A selected annotation comes first, even with a
    /// tool on; notes keep their colour (nil disables the menu).
    var currentColor: RGBAColor? {
        if let selected = session.selectedAnnotations.first {
            return selected.isRecolorable ? selected.color : nil
        }
        switch tool {
        case .highlight: return highlightColor
        case .underline: return underlineColor
        case .note, .latex, .text, nil: return nil
        }
    }

    func chooseColor(_ newColor: RGBAColor) {
        if let selected = session.selectedAnnotations.first {
            if selected.isRecolorable {
                session.recolorItem(selected.itemID, to: newColor)
            }
            return
        }
        switch tool {
        case .highlight: highlightColor = newColor
        case .underline: underlineColor = newColor
        case .note, .latex, .text, nil: break
        }
    }

    @discardableResult
    func deleteSelection() -> Bool {
        guard session.canEdit, let selection = session.selection else {
            return false
        }
        session.deleteItem(selection)
        return true
    }

    /// Esc on the page: turn the tool off, or deselect.
    func cancel() -> Bool {
        if tool != nil {
            tool = nil
            session.select(nil)
        } else if session.selection != nil {
            session.select(nil)
        } else {
            return false
        }
        return true
    }

    func reveal(_ itemID: UUID) {
        session.select(itemID)
        let items = session.annotations.item(itemID)
        guard let first = items.first,
            let page = pdfView.document?.page(at: first.pageIndex)
        else { return }
        pdfView.go(
            to: unionRect(of: items).insetBy(dx: -40, dy: -80), on: page)
    }

    func text(under annotation: Annotation) -> String {
        if let text = textUnder[annotation.id] { return text }
        guard let page = pdfView.document?.page(at: annotation.pageIndex)
        else { return "" }
        let core = annotation.bounds.insetBy(
            dx: 0, dy: annotation.bounds.height * 0.3)
        let text =
            page.selection(for: core)?.string?.trimmingCharacters(
                in: .whitespacesAndNewlines) ?? ""
        textUnder[annotation.id] = text
        return text
    }

    // MARK: Adding

    private func addMarkup(_ kind: Annotation.Kind, color: RGBAColor) {
        guard session.canEdit, hasTextSelection,
            let selection = pdfView.currentSelection,
            let document = pdfView.document
        else {
            return
        }
        let lines = selection.selectionsByLine().compactMap {
            line -> (pageIndex: Int, rect: CGRect)? in
            guard let page = line.pages.first else { return nil }
            let rect = line.bounds(for: page)
            guard rect.width > 1, rect.height > 1 else { return nil }
            return (document.index(for: page), rect)
        }
        session.addMarkup(kind, lines: lines, color: color)
        pdfView.clearSelection()
    }

    /// A note attached to the selected text, with its icon at the end of the
    /// selection.
    private func addNoteToSelection() {
        guard let selection = pdfView.currentSelection,
            let document = pdfView.document,
            let lastLine = selection.selectionsByLine().last,
            let page = lastLine.pages.first
        else { return }
        let anchors = selection.selectionsByLine().compactMap { line in
            line.pages.first == page ? line.bounds(for: page) : nil
        }
        let end = lastLine.bounds(for: page)
        var icon = CGRect(
            x: end.maxX + 2, y: end.maxY - Self.noteSize, width: Self.noteSize,
            height: Self.noteSize)
        let box = page.bounds(for: pdfView.displayBox)
        icon.origin.x = min(max(icon.minX, box.minX), box.maxX - icon.width)
        icon.origin.y = min(max(icon.minY, box.minY), box.maxY - icon.height)
        pdfView.clearSelection()
        guard
            let id = session.beginNote(
                pageIndex: document.index(for: page), iconRect: icon,
                anchorRects: anchors,
                color: Palette.noteYellow)
        else { return }
        popover.editNote(id, isNew: true)
    }

    /// Places a new formula or text box with its top-left corner where the
    /// page was clicked.
    private func place(_ tool: Tool, on page: PDFPage, at point: CGPoint) {
        guard let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        switch tool {
        case .latex:
            let fontSize = popover.latexFontSize
            let bounds = box(
                of: LaTeXRenderer.size(of: "", fontSize: fontSize), at: point,
                on: page)
            guard
                let id = session.beginLaTeX(
                    pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
                    color: Palette.black)
            else {
                return
            }
            popover.editLaTeX(id, isNew: true)
        case .text:
            let fontSize = popover.textFontSize
            let bounds = box(
                of: TextBoxStyle.size(of: "", fontSize: fontSize), at: point,
                on: page)
            guard
                let id = session.beginTextBox(
                    pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
                    color: Palette.black)
            else {
                return
            }
            popover.editTextBox(id, isNew: true)
        case .highlight, .underline, .note:
            break
        }
    }

    /// A box of `size` with its top-left corner at `point`, moved in where it
    /// would leave the page.
    private func box(of size: CGSize, at point: CGPoint, on page: PDFPage)
        -> CGRect
    {
        let pageBox = page.bounds(for: pdfView.displayBox)
        let x = min(max(point.x, pageBox.minX), pageBox.maxX - size.width)
        let y = min(
            max(point.y - size.height, pageBox.minY),
            pageBox.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    // MARK: Mouse (from AnnotationPDFView)

    /// Returns whether the click was ours. If not, the PDFView handles it
    /// (text selection etc.).
    func mouseDown(
        on page: PDFPage, at point: CGPoint, clickCount: Int,
        timestamp: TimeInterval
    ) -> Bool {
        guard session.canEdit, let document = pdfView.document else {
            return false
        }
        editOnMouseUp = nil
        // A click on the page while an editor is open (or that just closed
        // one) only closes it: it doesn't select, drag or create anything.
        if popover.isOpen {
            if popover.tryToFinish() { session.select(nil) }
            return true
        }
        if popover.closed(by: timestamp) {
            session.select(nil)
            return true
        }
        let pageIndex = document.index(for: page)
        if let box = textBox(atRightEdge: point, pageIndex: pageIndex),
            case .textBox(let text, let fontSize) = box.kind,
            let mark = renderer.marks(ofItem: box.itemID).first
        {
            session.select(box.itemID)
            let pageBox = page.bounds(for: pdfView.displayBox),
                narrowest = TextBoxStyle.minimumWidth(fontSize: fontSize)
            gesture = .setWidth(
                WidthChange(
                    id: box.id, mark: mark, start: box.bounds, text: text,
                    fontSize: fontSize,
                    widths:
                        narrowest...max(
                            narrowest, pageBox.maxX - box.bounds.minX),
                    page: pageBox))
            return true
        }
        // With a tool on, only notes, formulas and text boxes take clicks.
        // Text under highlights, underlines and notes stays selectable, so it
        // can be marked again on top.
        let annotations = session.annotations
        let hit: Annotation?
        if tool == nil {
            hit = annotations.annotation(at: point, pageIndex: pageIndex)
        } else {
            hit = annotations.annotation(at: point, pageIndex: pageIndex) {
                switch $0.kind {
                case .note, .latex, .textBox: [$0.bounds]
                case .highlight, .underline: []
                }
            }
        }
        guard let hit else {
            // With a tool on, a click that deselects does only that; the next
            // click uses the tool.
            let wasSelected = session.selection != nil
            session.select(nil)
            return tool != nil && wasSelected
        }
        session.select(hit.itemID)
        if clickCount == 2 {
            switch hit.kind {
            case .note, .latex, .textBox:
                editOnMouseUp = hit
                return true
            case .highlight, .underline: break
            }
        }
        guard hit.isMovable else { return true }
        let box = page.bounds(for: pdfView.displayBox)
        let rect = unionRect(of: session.annotations.item(hit.itemID))
        let limits = CGRect(
            x: box.minX - rect.minX, y: box.minY - rect.minY,
            width: box.width - rect.width, height: box.height - rect.height)
        gesture = .move(
            Move(
                itemID: hit.itemID,
                origins: renderer.marks(ofItem: hit.itemID).map {
                    ($0, $0.bounds)
                }, limits: limits))
        return true
    }

    /// Shows a move or a width change on screen while dragging; it's committed
    /// on mouse up.
    func dragMoved(by offset: CGSize) {
        switch gesture {
        case .move(let move):
            let offset = move.clamped(offset)
            for (mark, bounds) in move.origins {
                mark.bounds = bounds.offsetBy(
                    dx: offset.width, dy: offset.height)
            }
        case .setWidth(let change):
            change.mark.bounds = change.bounds(movedBy: offset.width)
        case nil:
            break
        }
    }

    /// The end of a click or drag that `mouseDown` took: commits a move or a
    /// width change, or opens the editor a double-click asked for. The editor
    /// opens only once the click is over; opened during it, the page would
    /// keep the keyboard and typing wouldn't reach the editor.
    func mouseUp(movedBy offset: CGSize) {
        if let item = editOnMouseUp {
            editOnMouseUp = nil
            edit(item)
            return
        }
        guard let gesture else { return }
        self.gesture = nil
        switch gesture {
        case .move(let move):
            let offset = move.clamped(offset)
            if hypot(offset.width, offset.height) >= 2 {
                session.moveItem(move.itemID, by: offset)
            } else {
                for (mark, bounds) in move.origins { mark.bounds = bounds }
            }
        case .setWidth(let change):
            let bounds = change.bounds(movedBy: offset.width)
            if bounds.size != change.start.size {
                session.resizeTextBox(
                    change.id, to: bounds.size, within: change.page)
            } else {
                change.mark.bounds = change.start
            }
        }
    }

    var isSettingWidth: Bool {
        if case .setWidth = gesture { return true }
        return false
    }

    func isOnTextBoxEdge(_ point: CGPoint, on page: PDFPage) -> Bool {
        guard session.canEdit, !popover.isOpen, let document = pdfView.document
        else { return false }
        return textBox(
            atRightEdge: point, pageIndex: document.index(for: page)) != nil
    }

    /// The topmost text box whose right edge is within about 4 points on
    /// screen of `point`.
    private func textBox(atRightEdge point: CGPoint, pageIndex: Int)
        -> Annotation?
    {
        let reach = 4 / max(pdfView.scaleFactor, 0.01)
        return session.annotations.last { annotation in
            guard annotation.pageIndex == pageIndex,
                case .textBox = annotation.kind
            else { return false }
            let bounds = annotation.bounds
            return abs(point.x - bounds.maxX) <= reach
                && point.y >= bounds.minY - reach
                && point.y <= bounds.maxY + reach
        }
    }

    func contextMenu(on page: PDFPage, at point: CGPoint) -> NSMenu? {
        guard session.canEdit, let document = pdfView.document,
            let hit = session.annotations.annotation(
                at: point, pageIndex: document.index(for: page))
        else { return nil }
        session.select(hit.itemID)
        let menu = NSMenu()
        switch hit.kind {
        case .note:
            menu.addItem(
                ClosureMenuItem("Edit Note…") { [weak self] in self?.edit(hit)
                })
            menu.addItem(.separator())
        case .latex:
            menu.addItem(
                ClosureMenuItem("Edit LaTeX…") { [weak self] in self?.edit(hit)
                })
            menu.addItem(.separator())
        case .textBox:
            menu.addItem(
                ClosureMenuItem("Edit Text…") { [weak self] in self?.edit(hit)
                })
            menu.addItem(.separator())
        case .highlight, .underline:
            break
        }
        if hit.isRecolorable {
            let colours = NSMenu()
            for entry in Palette.entries {
                let item = ClosureMenuItem(entry.name) { [weak self] in
                    self?.session.recolorItem(hit.itemID, to: entry.color)
                }
                item.image = Palette.swatch(entry.color)
                item.state = hit.color == entry.color ? .on : .off
                colours.addItem(item)
            }
            let colourItem = NSMenuItem(
                title: "Colour", action: nil, keyEquivalent: "")
            colourItem.submenu = colours
            menu.addItem(colourItem)
            menu.addItem(.separator())
        }
        menu.addItem(
            ClosureMenuItem("Delete") { [weak self] in
                self?.session.deleteItem(hit.itemID)
            })
        return menu
    }

    private func edit(_ annotation: Annotation) {
        switch annotation.kind {
        case .note: popover.editNote(annotation.id, isNew: false)
        case .latex: popover.editLaTeX(annotation.id, isNew: false)
        case .textBox: popover.editTextBox(annotation.id, isNew: false)
        case .highlight, .underline: break
        }
    }

    private func unionRect(of annotations: [Annotation]) -> CGRect {
        annotations.flatMap(\.hitRects).reduce(CGRect.null) { $0.union($1) }
    }
}
