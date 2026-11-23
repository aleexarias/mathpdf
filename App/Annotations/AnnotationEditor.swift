import AppKit
import MathPDFCore
import MathPDFLaTeX
import MathPDFRendering
import Observation
import PDFKit
import UniformTypeIdentifiers

/// Turns clicks, drags and toolbar actions into changes to the session. The
/// pages are drawn by `AnnotationRenderer`; notes and formulas are written in
/// `EditorPopoverController`. One per window.
@MainActor @Observable
final class AnnotationEditor: NSObject {
    /// Tools stay on until turned off. With the highlighter or underliner on,
    /// selecting text marks it; with the note tool on, selecting text (or
    /// clicking a word) attaches a note.
    enum Tool {
        case highlight, underline, note

        var name: String {
            switch self {
            case .highlight: "Highlight"
            case .underline: "Underline"
            case .note: "Note"
            }
        }
    }

    private(set) var tool: Tool?
    private(set) var highlightColor = Palette.yellow
    private(set) var underlineColor = Palette.lightRed
    private(set) var hasTextSelection = false

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
        case resize(Resize)
        case crop(ImageGeometry.Sides, from: Cropping.Shown)
    }

    /// An item being dragged: its marks where they started, and how far each
    /// way it can move without leaving its page.
    private struct Move {
        let itemID: UUID
        let origins: [(mark: PDFAnnotation, bounds: CGRect)]
        let limits: CGRect

        func clamped(_ offset: CGSize) -> CGSize {
            CGSize(
                width: offset.width.clamped(to: limits.minX...limits.maxX),
                height: offset.height.clamped(to: limits.minY...limits.maxY))
        }
    }

    /// A text box's width being set by dragging its right edge: the text wraps
    /// to it, the height follows, and the top-left corner stays put. All as
    /// seen on screen.
    private struct WidthChange {
        let id: UUID
        let mark: PDFAnnotation
        let start: CGRect
        let layout: TextBoxLayout
        /// From the narrowest a box can be to the page's right edge.
        let widths: ClosedRange<CGFloat>
        let frame: PageFrame

        @MainActor
        func bounds(movedBy offset: CGSize) -> CGRect {
            let shown = frame.shown(start)
            let wanted = shown.width + frame.shown(offset).width
            let width = min(
                max(wanted, widths.lowerBound), widths.upperBound)
            let size = layout.size(width: width)
            return frame.onPage(
                CGRect(
                    x: shown.minX, y: shown.maxY - size.height,
                    width: size.width, height: size.height))
        }
    }

    /// An image being resized by dragging a corner; see `ImageGeometry`.
    private struct Resize {
        let id: UUID
        let mark: PDFAnnotation
        let start: CGRect
        let corner: ImageGeometry.Corner
        let frame: PageFrame

        func bounds(movedBy offset: CGSize) -> CGRect {
            ImageGeometry.resized(
                start, dragging: corner, by: offset, on: frame)
        }
    }

    /// An image while its crop is changed: its mark shows the whole image,
    /// dimming what's cropped away, until the crop is kept or given up.
    private struct Cropping {
        struct Shown: Equatable {
            var bounds: CGRect
            var crop: CGRect
        }

        let id: UUID
        let mark: ImageAnnotation
        let frame: PageFrame
        let start: Shown
        var kept: Shown
    }

    @ObservationIgnored private var cropping: Cropping?

    /// How far from a handle of the selected image, in points on screen, a
    /// click takes it.
    private static let handleReach: CGFloat = 8

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

    var onPagesRedrawn: (([Int]) -> Void)? {
        get { renderer.onPagesRedrawn }
        set { renderer.onPagesRedrawn = newValue }
    }

    func documentReplaced() {
        gesture = nil
        pdfView.liftedImage.clear()
        editOnMouseUp = nil
        renderer.documentReplaced()
    }

    func redrawAnnotations() {
        renderer.redraw()
    }

    /// While a note or formula is being written the page stays put, so it
    /// stays under its editor.
    var isEditingItem: Bool { popover.isOpen }

    /// Finishes an open note or formula editor, as a click elsewhere would,
    /// and keeps a crop being changed. False if the editor stays open because
    /// the formula has an error, which is then shown.
    func finishEditing() -> Bool {
        finishCropping(keeping: true)
        return popover.tryToFinish()
    }

    func closeEditor() {
        popover.close()
        finishCropping(keeping: true)
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
        finishCropping(keeping: true)
        // a formula with an error is shown first
        guard popover.tryToFinish() else { return }
        if hasTextSelection {
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
        }
    }

    /// Called when the mouse goes up after a click or text selection on the
    /// page, with where.
    func useTool(at location: (page: PDFPage, point: CGPoint)?) {
        guard let tool, session.canEdit else { return }
        if !hasTextSelection, let (page, point) = location,
            let pageIndex = pdfView.index(of: page),
            let hit = session.annotations.annotation(
                at: point, pageIndex: pageIndex)
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
        case .note, nil: return nil
        }
    }

    func chooseColor(_ newColor: RGBAColor) {
        if let selected = session.selectedAnnotations.first {
            if selected.isRecolorable { recolor(selected, to: newColor) }
            return
        }
        switch tool {
        case .highlight: highlightColor = newColor
        case .underline: underlineColor = newColor
        case .note, nil: break
        }
    }

    /// Moves the selected highlight or underline, or else the highlighter or
    /// underliner that's on, to the next colour in the rotation. Beeps if
    /// there's nothing of either.
    func cycleColor(backwards: Bool) {
        let selected = session.selectedAnnotations.first?.kind
        guard session.canEdit,
            selected == nil || selected == .highlight
                || selected == .underline,
            let current = currentColor,
            let next = ColorRotation.shared.color(
                after: current, backwards: backwards)
        else { return NSSound.beep() }
        chooseColor(next)
    }

    @discardableResult
    func deleteSelection() -> Bool {
        guard session.canEdit, let selection = session.selection else {
            return false
        }
        finishCropping(keeping: false)
        session.deleteItem(selection)
        return true
    }

    /// Esc on the page: give up a crop, turn the tool off, or deselect.
    func cancel() -> Bool {
        if finishCropping(keeping: false) {
            return true
        } else if tool != nil {
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
        let rect = unionRect(of: items)
        pdfView.go(to: rect.insetBy(dx: -40, dy: -80), on: page)
        pdfView.keepInView(rect, on: page)
    }

    func text(under annotation: Annotation) -> String {
        if let text = textUnder[annotation.id] { return text }
        guard let page = pdfView.document?.page(at: annotation.pageIndex)
        else { return "" }
        let core = pdfView.pageFrame(of: page).middleOfLine(annotation.bounds)
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
            let lastLine = selection.selectionsByLine().last,
            let page = lastLine.pages.first,
            let pageIndex = pdfView.index(of: page)
        else { return }
        let anchors = selection.selectionsByLine().compactMap { line in
            line.pages.first == page ? line.bounds(for: page) : nil
        }
        let frame = pdfView.pageFrame(of: page)
        let end = frame.shown(lastLine.bounds(for: page))
        let icon = frame.onPage(
            frame.keptOnPage(
                CGRect(
                    x: end.maxX + 2, y: end.maxY - Self.noteSize,
                    width: Self.noteSize, height: Self.noteSize)))
        pdfView.clearSelection()
        guard
            let id = session.beginNote(
                pageIndex: pageIndex, iconRect: icon,
                anchorRects: anchors,
                color: Palette.noteYellow)
        else { return }
        popover.edit(id, isNew: true)
    }

    var writing: WritingDefaults {
        get { popover.writing }
        set { popover.writing = newValue }
    }

    var onWritingChanged: (() -> Void)? {
        get { popover.onWritingChanged }
        set { popover.onWritingChanged = newValue }
    }

    private func recolor(_ annotation: Annotation, to color: RGBAColor) {
        session.recolorItem(annotation.itemID, to: color)
        switch annotation.kind {
        case .latex, .textBox: writing.color = color
        case .highlight, .underline, .note, .image: break
        }
    }

    func addFormula() {
        addItem(
            fontSize: \.formulaSize,
            size: { LaTeXRenderer.size(of: "", fontSize: $0) },
            begin: session.beginLaTeX)
    }

    func addTextBox() {
        addItem(
            fontSize: \.textSize,
            size: { TextBoxStyle.size(of: "", fontSize: $0) },
            begin: session.beginTextBox)
    }

    /// Adds an empty formula or text box in the middle of the view and opens
    /// its editor. The font size is read after what was being written has
    /// made way, as finishing that is what sets it.
    private func addItem(
        fontSize: KeyPath<WritingDefaults, Double>,
        size: (Double) -> CGSize,
        begin: (Int, CGRect, Double, RGBAColor) -> UUID?
    ) {
        guard let (page, pageIndex, centre) = placeForNewItem() else { return }
        let fontSize = writing[keyPath: fontSize]
        let bounds = pdfView.pageFrame(of: page).box(
            ofShownSize: size(fontSize), centredAt: centre)
        guard let id = begin(pageIndex, bounds, fontSize, writing.color)
        else { return }
        popover.edit(id, isNew: true)
    }

    /// The page at the centre of what's on screen, or the nearest if that's
    /// between pages. Whatever is being written makes way: it's kept if it's
    /// valid, and otherwise given up on without asking.
    private func placeForNewItem() -> (
        page: PDFPage, index: Int, centre: CGPoint
    )? {
        guard session.canEdit else {
            NSSound.beep()
            return nil
        }
        popover.close()
        finishCropping(keeping: true)
        guard let (page, centre) = middleOfView,
            let pageIndex = pdfView.index(of: page)
        else { return nil }
        session.select(nil)
        return (page, pageIndex, centre)
    }

    private var middleOfView: (page: PDFPage, centre: CGPoint)? {
        let area = pdfView.uncoveredRect
        let centre = CGPoint(x: area.midX, y: area.midY)
        guard let page = pdfView.page(for: centre, nearest: true) else {
            return nil
        }
        return (page, pdfView.convert(centre, to: page))
    }

    // MARK: Images

    var canPasteImage: Bool { session.canEdit && ImageClipboard.hasImage() }

    func pasteImage() {
        guard session.canEdit, let source = ImageClipboard.read() else {
            return NSSound.beep()
        }
        addImage(from: source)
    }

    /// Asks for an image file to add.
    func chooseImage() {
        guard session.canEdit, let window = pdfView.window else {
            return NSSound.beep()
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addImage(from: .file(url))
        }
    }

    /// Prepares and stores the image away from the main thread, then adds it
    /// in the middle of the view: never before its file is on disk, nor
    /// before it's decoded. Until then the page would draw an empty box, and
    /// PDFKit can miss being asked to draw it again.
    private func addImage(from source: ImageSource) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    () throws -> PreparedImage in
                    switch source {
                    case .data(let data): try ImageImport.prepare(data)
                    case .file(let url):
                        try ImageImport.prepare(contentsOf: url)
                    }
                }.value
                try await Persistence.images.store(image)
                Persistence.imageCache.stored(image.hash)
                let reference = ImageReference(
                    hash: image.hash, pixelSize: image.pixelSize)
                if let pixels = pixelsShown(of: reference) {
                    await Persistence.imageCache.prepare(
                        reference, longestSide: pixels)
                }
                place(reference)
            } catch {
                session.notice = .error(error.localizedDescription)
            }
        }
    }

    private func place(_ image: ImageReference) {
        guard let (page, pageIndex, centre) = placeForNewItem() else { return }
        let frame = pdfView.pageFrame(of: page)
        session.addImage(
            image, pageIndex: pageIndex,
            bounds: frame.box(
                ofShownSize: shownSize(of: image.pixelSize, on: frame),
                centredAt: centre),
            within: frame)
    }

    /// Screen pixels along its longer side, added now.
    private func pixelsShown(of image: ImageReference) -> CGFloat? {
        guard let page = middleOfView?.page else { return nil }
        let size = shownSize(
            of: image.pixelSize, on: pdfView.pageFrame(of: page))
        return max(size.width, size.height) * pdfView.scaleFactor
            * (pdfView.window?.backingScaleFactor ?? 2)
    }

    /// A point a pixel, made smaller to fit in half of what's visible and on
    /// its page.
    private func shownSize(of pixels: CGSize, on frame: PageFrame) -> CGSize {
        let visible = pdfView.uncoveredRect.size
        let zoom = max(pdfView.scaleFactor, 0.01)
        let room = CGSize(
            width: min(visible.width / zoom / 2, frame.shownSize.width),
            height: min(visible.height / zoom / 2, frame.shownSize.height))
        let scale = min(
            1, room.width / pixels.width, room.height / pixels.height)
        return CGSize(
            width: pixels.width * scale, height: pixels.height * scale)
    }

    // MARK: Cropping

    /// Return on the page: start or keep cropping the selected image.
    func toggleCropping() -> Bool {
        if finishCropping(keeping: true) { return true }
        guard let image = selectedImage else { return false }
        startCropping(image)
        return true
    }

    private var selectedImage: Annotation? {
        session.annotations.first {
            guard $0.itemID == session.selection, case .image = $0.kind else {
                return false
            }
            return true
        }
    }

    private func startCropping(_ image: Annotation) {
        guard session.canEdit, case .image(let reference) = image.kind,
            let mark = renderer.marks(ofItem: image.itemID).first
                as? ImageAnnotation,
            let page = mark.page
        else { return }
        finishCropping(keeping: true)
        let frame = pdfView.pageFrame(of: page)
        let shown = Cropping.Shown(bounds: image.bounds, crop: reference.crop)
        liftImage(mark)
        mark.bounds = ImageGeometry.whole(
            image.bounds, crop: reference.crop, on: frame)
        mark.editingCrop = reference.crop
        cropping = Cropping(
            id: image.id, mark: mark, frame: frame, start: shown, kept: shown)
        pdfView.outline = .init(mark: mark, kept: reference.crop)
    }

    /// Keeps the crop, or gives it up. False if nothing was being cropped.
    @discardableResult
    private func finishCropping(keeping: Bool) -> Bool {
        guard let cropping else { return false }
        self.cropping = nil
        let mark = cropping.mark
        mark.editingCrop = nil
        mark.bounds = cropping.start.bounds
        pdfView.outline = .init(mark: mark)
        // an undo can have redrawn the image meanwhile
        if keeping, mark.page != nil, cropping.kept != cropping.start {
            session.cropImage(
                cropping.id, to: cropping.kept.crop,
                bounds: cropping.kept.bounds, within: cropping.frame)
        }
        putBackImage(cropping.id)
        return true
    }

    /// Shows an image above the pages from the start of a gesture, before
    /// it changes: the page takes a moment to be drawn without it.
    private func liftImage(_ mark: PDFAnnotation?) {
        if let image = mark as? ImageAnnotation {
            pdfView.liftedImage.lift(image, from: image.bounds)
        }
    }

    /// Puts the image lifted for a gesture back, showing what's drawn for
    /// it on its page now.
    private func putBackImage(_ id: UUID) {
        let mark = session.annotations.first { $0.id == id }.flatMap {
            renderer.marks(ofItem: $0.itemID).first
        }
        pdfView.liftedImage.putBack(showing: mark as? ImageAnnotation)
    }

    private func changeCrop(
        moving sides: ImageGeometry.Sides, from start: Cropping.Shown,
        by offset: CGSize
    ) {
        guard var cropping else { return }
        let (bounds, crop) = ImageGeometry.cropped(
            start.bounds, crop: start.crop, moving: sides, by: offset,
            on: cropping.frame)
        cropping.kept = Cropping.Shown(bounds: bounds, crop: crop)
        self.cropping = cropping
        cropping.mark.editingCrop = crop
        pdfView.outline = .init(mark: cropping.mark, kept: crop)
    }

    private func startChangingCrop(at point: CGPoint, on page: PDFPage)
        -> Bool
    {
        guard let sides = cropHandle(at: point, on: page),
            let kept = cropping?.kept
        else { return false }
        gesture = .crop(sides, from: kept)
        return true
    }

    /// The crop handle at `point`, on the image being cropped.
    private func cropHandle(at point: CGPoint, on page: PDFPage)
        -> ImageGeometry.Sides?
    {
        guard let cropping, cropping.mark.page === page else { return nil }
        let kept = cropping.frame.shown(cropping.kept.bounds)
        let pointer = cropping.frame.shown(point)
        let reach = Self.handleReach / max(pdfView.scaleFactor, 0.01)
        return ImageGeometry.Sides.cropHandles.first {
            let handle = $0.point(of: kept)
            return abs(pointer.x - handle.x) <= reach
                && abs(pointer.y - handle.y) <= reach
        }
    }

    private func isInKeptPart(_ point: CGPoint, on page: PDFPage) -> Bool {
        guard let cropping, cropping.mark.page === page else { return false }
        return cropping.kept.bounds.contains(point)
    }

    private func resetCrop(_ image: Annotation) {
        guard case .image(let reference) = image.kind,
            let page = pdfView.document?.page(at: image.pageIndex)
        else { return }
        let frame = pdfView.pageFrame(of: page)
        session.cropImage(
            image.id, to: ImageReference.uncropped,
            bounds: ImageGeometry.uncropped(
                image.bounds, crop: reference.crop, on: frame),
            within: frame)
    }

    // MARK: Mouse (from AnnotationPDFView)

    /// Returns whether the click was ours. If not, the PDFView handles it
    /// (text selection etc.).
    func mouseDown(
        on page: PDFPage, at point: CGPoint, clickCount: Int,
        timestamp: TimeInterval
    ) -> Bool {
        guard session.canEdit, let pageIndex = pdfView.index(of: page) else {
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
        if cropping != nil {
            return startChangingCrop(at: point, on: page)
                || isInKeptPart(point, on: page)
                || finishCropping(keeping: true)
        }
        if startSettingWidth(at: point, on: page, pageIndex: pageIndex)
            || startResizing(at: point, on: page, pageIndex: pageIndex)
        {
            return true
        }
        // With a tool on, only notes, formulas and text boxes take clicks.
        // Text under highlights, underlines and notes stays selectable, so it
        // can be marked again on top.
        let hit =
            tool == nil
            ? session.annotations.annotation(at: point, pageIndex: pageIndex)
            : box(at: point, pageIndex: pageIndex)
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
            case .image:
                startCropping(hit)
                return true
            case .highlight, .underline: break
            }
        }
        if hit.isMovable { startMoving(hit, on: page) }
        return true
    }

    private func startSettingWidth(
        at point: CGPoint, on page: PDFPage, pageIndex: Int
    ) -> Bool {
        guard let box = textBox(atRightEdge: point, pageIndex: pageIndex),
            case .textBox(let text, let fontSize, let expanded) = box.kind,
            let mark = renderer.marks(ofItem: box.itemID).first
        else { return false }
        session.select(box.itemID)
        let frame = pdfView.pageFrame(of: page)
        let layout = TextBoxLayout(expanded ?? text, fontSize: fontSize)
        let narrowest = layout.minimumWidth
        let toPageEdge = frame.shownSize.width - frame.shown(box.bounds).minX
        gesture = .setWidth(
            WidthChange(
                id: box.id, mark: mark, start: box.bounds, layout: layout,
                widths: narrowest...max(narrowest, toPageEdge), frame: frame))
        return true
    }

    private func startResizing(
        at point: CGPoint, on page: PDFPage, pageIndex: Int
    ) -> Bool {
        guard
            let (image, corner) = imageCorner(
                at: point, on: page, pageIndex: pageIndex),
            let mark = renderer.marks(ofItem: image.itemID).first
        else { return false }
        gesture = .resize(
            Resize(
                id: image.id, mark: mark, start: image.bounds, corner: corner,
                frame: pdfView.pageFrame(of: page)))
        liftImage(mark)
        return true
    }

    /// The selected image, and which of its corners as seen on screen
    /// `point` is on.
    private func imageCorner(
        at point: CGPoint, on page: PDFPage, pageIndex: Int
    ) -> (Annotation, ImageGeometry.Corner)? {
        guard let image = selectedImage, image.pageIndex == pageIndex else {
            return nil
        }
        let frame = pdfView.pageFrame(of: page)
        let shown = frame.shown(image.bounds)
        let pointer = frame.shown(point)
        let reach = Self.handleReach / max(pdfView.scaleFactor, 0.01)
        return ImageGeometry.Corner.allCases.first {
            let corner = $0.point(of: shown)
            return abs(pointer.x - corner.x) <= reach
                && abs(pointer.y - corner.y) <= reach
        }.map { (image, $0) }
    }

    private func startMoving(_ item: Annotation, on page: PDFPage) {
        let box = page.bounds(for: pdfView.displayBox)
        let rect = unionRect(of: session.annotations.item(item.itemID))
        gesture = .move(
            Move(
                itemID: item.itemID,
                origins: renderer.marks(ofItem: item.itemID).map {
                    ($0, $0.bounds)
                },
                limits: CGRect(
                    x: box.minX - rect.minX, y: box.minY - rect.minY,
                    width: box.width - rect.width,
                    height: box.height - rect.height)))
        liftImage(renderer.marks(ofItem: item.itemID).first)
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
            change.mark.bounds = change.bounds(movedBy: offset)
        case .resize(let resize):
            resize.mark.bounds = resize.bounds(movedBy: offset)
        case .crop(let sides, let start):
            changeCrop(moving: sides, from: start, by: offset)
        case nil:
            break
        }
        pdfView.updateOutline()
    }

    /// The end of a click or drag that `mouseDown` took: commits a move or a
    /// resize, or opens the editor a double-click asked for. The editor
    /// opens only once the click is over; opened during it, the page would
    /// keep the keyboard and typing wouldn't reach the editor.
    func mouseUp(movedBy offset: CGSize) {
        if let item = editOnMouseUp {
            editOnMouseUp = nil
            popover.edit(item.id, isNew: false)
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
            pdfView.liftedImage.putBack(
                showing: renderer.marks(ofItem: move.itemID).first
                    as? ImageAnnotation)
        case .setWidth(let change):
            let bounds = change.bounds(movedBy: offset)
            if bounds.size != change.start.size {
                session.resizeTextBox(
                    change.id, to: change.frame.turned(bounds.size),
                    within: change.frame)
            } else {
                change.mark.bounds = change.start
            }
        case .resize(let resize):
            // the session redraws it if the resize is taken
            resize.mark.bounds = resize.start
            session.resizeImage(
                resize.id, to: resize.bounds(movedBy: offset),
                within: resize.frame)
            putBackImage(resize.id)
        case .crop(let sides, let start):
            changeCrop(moving: sides, from: start, by: offset)
        }
        pdfView.updateOutline()
    }

    /// The pointer for the drag under way, if it needs one PDFKit wouldn't
    /// show.
    var gestureCursor: NSCursor? {
        switch gesture {
        case .setWidth: .resizeLeftRight
        case .resize(let resize): Self.cursor(resizing: resize.corner.sides)
        case .crop(let sides, _): Self.cursor(resizing: sides)
        case .move, nil: nil
        }
    }

    /// The pointer over `point`: for resizing a text box or the selected
    /// image, an arrow over a note, formula, text box or image, or nil for
    /// PDFKit's own.
    func cursor(at point: CGPoint, on page: PDFPage) -> NSCursor? {
        guard let pageIndex = pdfView.index(of: page) else { return nil }
        if cropping != nil {
            return cropHandle(at: point, on: page).map(Self.cursor(resizing:))
                ?? (isInKeptPart(point, on: page) ? .arrow : nil)
        }
        if session.canEdit, !popover.isOpen {
            if let (_, corner) = imageCorner(
                at: point, on: page, pageIndex: pageIndex)
            {
                return Self.cursor(resizing: corner.sides)
            }
            if textBox(atRightEdge: point, pageIndex: pageIndex) != nil {
                return .resizeLeftRight
            }
        }
        return box(at: point, pageIndex: pageIndex) != nil ? .arrow : nil
    }

    private static func cursor(resizing sides: ImageGeometry.Sides)
        -> NSCursor
    {
        let horizontal = sides.isDisjoint(with: [.top, .bottom])
        let vertical = sides.isDisjoint(with: [.left, .right])
        guard #available(macOS 15, *) else {
            return horizontal
                ? .resizeLeftRight : vertical ? .resizeUpDown : .crosshair
        }
        let position: NSCursor.FrameResizePosition =
            switch (sides.contains(.top), sides.contains(.bottom)) {
            case (true, _):
                sides.contains(.left)
                    ? .topLeft : sides.contains(.right) ? .topRight : .top
            case (_, true):
                sides.contains(.left)
                    ? .bottomLeft
                    : sides.contains(.right) ? .bottomRight : .bottom
            default: sides.contains(.left) ? .left : .right
            }
        return .frameResize(position: position, directions: .all)
    }

    /// The topmost note, formula, text box or image at `point`.
    private func box(at point: CGPoint, pageIndex: Int) -> Annotation? {
        session.annotations.annotation(at: point, pageIndex: pageIndex) {
            switch $0.kind {
            case .note, .latex, .textBox, .image: [$0.bounds]
            case .highlight, .underline: []
            }
        }
    }

    /// The topmost text box whose right edge on screen is within about 4
    /// points of `point`.
    private func textBox(atRightEdge point: CGPoint, pageIndex: Int)
        -> Annotation?
    {
        guard let page = pdfView.document?.page(at: pageIndex) else {
            return nil
        }
        let frame = pdfView.pageFrame(of: page)
        let shown = frame.shown(point)
        let reach = 4 / max(pdfView.scaleFactor, 0.01)
        return session.annotations.last { annotation in
            guard annotation.pageIndex == pageIndex,
                case .textBox = annotation.kind
            else { return false }
            let bounds = frame.shown(annotation.bounds)
            return abs(shown.x - bounds.maxX) <= reach
                && shown.y >= bounds.minY - reach
                && shown.y <= bounds.maxY + reach
        }
    }

    func contextMenu(on page: PDFPage, at point: CGPoint) -> NSMenu? {
        guard session.canEdit, let pageIndex = pdfView.index(of: page),
            let hit = session.annotations.annotation(
                at: point, pageIndex: pageIndex)
        else { return nil }
        finishCropping(keeping: true)
        session.select(hit.itemID)
        let menu = NSMenu()
        if case .image(let image) = hit.kind {
            menu.addItem(
                ClosureMenuItem("Crop") { [weak self] in
                    self?.startCropping(hit)
                })
            if image.crop != ImageReference.uncropped {
                menu.addItem(
                    ClosureMenuItem("Reset Crop") { [weak self] in
                        self?.resetCrop(hit)
                    })
            }
            menu.addItem(.separator())
        }
        let editTitle: String? =
            switch hit.kind {
            case .note: "Edit Note…"
            case .latex: "Edit LaTeX…"
            case .textBox: "Edit Text…"
            case .highlight, .underline, .image: nil
            }
        if let editTitle {
            menu.addItem(
                ClosureMenuItem(editTitle) { [weak self] in
                    self?.popover.edit(hit.id, isNew: false)
                })
            menu.addItem(.separator())
        }
        if hit.isRecolorable {
            let colours = NSMenu()
            for entry in Palette.entries {
                let item = ClosureMenuItem(entry.name) { [weak self] in
                    self?.recolor(hit, to: entry.color)
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

    private func unionRect(of annotations: [Annotation]) -> CGRect {
        annotations.flatMap(\.hitRects).reduce(CGRect.null) { $0.union($1) }
    }
}
