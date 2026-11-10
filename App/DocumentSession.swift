import MathPDFCore
import MathPDFRendering
import Observation
import PDFKit

/// One open PDF: the document, its annotations, and how they are saved.
/// Annotations never change the PDF; moving, deleting and pasting pages does
/// (see `DocumentSession+Pages`).
@MainActor @Observable
final class DocumentSession {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// Something the user needs to know about the saved annotations, shown
    /// above the page.
    enum Notice {
        case recovered(
            problem: String, snapshotDate: Date, annotationCount: Int)
        case blocked(AnnotationStore.BlockReason)
        case relinkSuggested(AnnotationStore.StoredSetSummary)
        case relinked(fileName: String, annotationCount: Int, leftOut: Int)
        case exporting(URL)
        /// `id` tells one export's confirmation from the next, so each goes
        /// away on its own time.
        case exported(URL, annotationCount: Int, id: UUID)
        case error(String)
    }

    enum SaveStatus { case saved, edited, failed }

    /// Tells this window's pages apart from another's when they're dragged.
    let id = UUID()
    private(set) var pdf: PDFDocument?
    let fileURL: URL?
    let autosaver = Autosaver(store: Persistence.store)
    private(set) var phase: Phase = .loading
    private(set) var annotationSet: AnnotationSet? {
        didSet {
            if let selection,
                !annotations.contains(where: { $0.itemID == selection })
            {
                self.selection = nil
            }
            onChange?()
            OpenDocuments.shared.annotationsChanged(in: self)
        }
    }
    /// The window that changes these annotations, when it isn't this one. See
    /// `OpenDocuments`.
    private(set) weak var editingSession: DocumentSession?
    /// Set once the window has closed, which can be while still loading.
    @ObservationIgnored var isWindowClosed = false
    /// PDFKit won't put annotations on a locked PDF, or on one whose security
    /// settings don't allow commenting. A locked PDF asks for its password
    /// where its pages would be (see `readProtection`).
    private(set) var isLocked = false
    private(set) var allowsCommenting = true
    /// The file no longer holds the PDF shown here (see `checkFile`).
    private(set) var isFileChangedElsewhere = false
    @ObservationIgnored private var checkedFileDate: Date?
    /// The selected annotation item: a multi-line markup's `groupID`, or a
    /// single annotation's ID.
    private(set) var selection: UUID? {
        didSet { if selection != oldValue { onChange?() } }
    }
    /// False while the stored data can't be used, so nothing gets overwritten.
    private(set) var savingAllowed = false
    /// Nothing else can change while pages are being written.
    private(set) var isChangingPages = false
    var notice: Notice?
    /// Other annotation sets on disk, best matches first. Offered when this
    /// PDF's hash is new.
    private(set) var relinkCandidates: [AnnotationStore.StoredSetSummary] = []
    var isShowingRelinkSheet = false

    /// The window's undo manager. Set by the viewer once the window exists.
    @ObservationIgnored var undoManagerProvider: (() -> UndoManager?)?
    /// Called after the annotations or the selection change, so the pages can
    /// be redrawn.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The PDF's bytes: as opened, then as written by each page change.
    @ObservationIgnored private(set) var data: Data
    /// The window's document. Writing the PDF tells it the change is ours, so
    /// it doesn't treat it as one made by another app.
    @ObservationIgnored var fileDocumentProvider: (() -> NSDocument?)?
    /// Called when the pages have changed, before the annotations follow, with
    /// where each earlier page went (nil if it was deleted).
    @ObservationIgnored var onPagesChanged: (([Int?]) -> Void)?
    /// The document's ID and its pages' IDs, kept with each page order, so
    /// annotations of any version can be put on the pages of any other.
    @ObservationIgnored private(set) var pageIdentity: PageIdentity?
    /// The last page change queued.
    @ObservationIgnored private var pageTask: Task<Bool, Never>?
    /// The last export started.
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init(data: Data, fileURL: URL?) {
        self.data = data
        self.fileURL = fileURL
        pdf = PDFDocument(data: data)
        if pdf == nil {
            phase = .failed("This file couldn't be opened as a PDF.")
        }
        readProtection()
    }

    /// Also after unlocking: the right password can lift the restrictions.
    func readProtection() {
        isLocked = pdf?.isLocked ?? false
        allowsCommenting = pdf?.allowsCommenting ?? true
    }

    /// The document follows the file if it's moved while open.
    var currentFileURL: URL? {
        fileDocumentProvider?()?.fileURL ?? fileURL
    }

    var fileName: String {
        currentFileURL?.lastPathComponent ?? "Untitled.pdf"
    }

    var dataFolderURL: URL? {
        annotationSet.map { Persistence.store.folderURL($0.documentHash) }
    }

    var annotations: [Annotation] { annotationSet?.annotations ?? [] }

    /// Annotations can't be changed while loading, while saving is blocked,
    /// while pages are being written, from a second window on one PDF, or when
    /// the PDF doesn't allow them.
    var canEdit: Bool { canWrite && !isLocked && allowsCommenting }

    var canWrite: Bool {
        phase == .ready && savingAllowed && editingSession == nil
            && !isChangingPages
    }

    /// For the title bar: "Edited" while changes aren't on disk yet.
    var saveStatus: SaveStatus {
        guard autosaver.hasUnsavedChanges else { return .saved }
        return autosaver.lastError == nil ? .edited : .failed
    }

    /// Relinking replaces this PDF's annotations, so it's only offered while
    /// there are none.
    var canRelink: Bool {
        canEdit && annotations.isEmpty
    }

    func load() async {
        guard let pdf, phase == .loading else { return }
        let data = data
        let hash = await Task.detached(priority: .userInitiated) {
            sha256Hex(data)
        }.value
        let blank = AnnotationSet(
            documentHash: hash, fileNameHint: fileName,
            pathHint: fileURL?.path ?? "",
            pageCount: pdf.pageCount)

        let result = await Persistence.store.load(documentHash: hash)
        switch result {
        case .fresh:
            annotationSet = blank
            savingAllowed = true
        case .loaded(let loaded, _):
            annotationSet = withCurrentLocation(loaded, from: blank)
            savingAllowed = true
        case .recovered(let loaded, let snapshot, let problem):
            annotationSet = withCurrentLocation(loaded, from: blank)
            savingAllowed = true
            notice = .recovered(
                problem: problem, snapshotDate: snapshot.date,
                annotationCount: loaded.annotations.count)
        case .blocked(let reason):
            annotationSet = blank
            savingAllowed = false
            notice = .blocked(reason)
        }
        let corrected = SidewaysBoxes.corrected(annotations, in: pdf)
        annotationSet?.annotations = corrected
        let stored = await Persistence.store.pageIdentity(documentHash: hash)
        pageIdentity =
            stored?.pageIDs.count == pdf.pageCount
            ? stored : PageIdentity(pageCount: pdf.pageCount)
        phase = .ready
        checkedFileDate = fileDate()
        OpenDocuments.shared.register(self)
        if case .fresh = result { await suggestRelink() }
    }

    func flush() async {
        await autosaver.flush()
    }

    // MARK: The file

    private func fileDate() -> Date? {
        currentFileURL.flatMap {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: $0.path)
            return attributes?[.modificationDate] as? Date
        }
    }

    /// Notices another app changing the file, like LaTeX compiling it again.
    /// This window stays on what it opened: that's what its annotations are
    /// stored for. Only looks inside the file if its date moved.
    func checkFile() async {
        guard !isChangingPages, let url = currentFileURL,
            let hash = annotationSet?.documentHash
        else { return }
        let date = fileDate()
        guard date != checkedFileDate else { return }
        checkedFileDate = date
        isFileChangedElsewhere = await Task.detached(priority: .utility) {
            (try? PDFFileWriter.checkUnchanged(url, hash: hash)) == nil
        }.value
    }

    // MARK: A second window on one PDF

    /// Leaves the annotations to `editor`, showing them as they change; nil
    /// takes them back, as they last were.
    func follow(_ editor: DocumentSession?) {
        if editor != nil, editingSession == nil {
            // what's left to undo would overwrite what the editor does
            undoManagerProvider?()?.removeAllActions(withTarget: self)
            if case .relinkSuggested? = notice { notice = nil }
        }
        editingSession = editor
        if let editor { showAnnotations(of: editor) }
    }

    func showAnnotations(of editor: DocumentSession) {
        guard let set = editor.annotationSet, let current = annotationSet,
            set.documentHash == current.documentHash
        else { return }
        annotationSet = withCurrentLocation(set, from: current)
    }

    /// The path is only a hint, refreshed on load; it's written with the next
    /// real change.
    private func withCurrentLocation(
        _ loaded: AnnotationSet, from blank: AnnotationSet
    ) -> AnnotationSet {
        var set = loaded
        set.fileNameHint = blank.fileNameHint
        set.pathHint = blank.pathHint
        return set
    }

    // MARK: Damaged data

    /// After `.blocked(.noValidData)`: start again from empty. The unreadable
    /// files stay on disk.
    func startFresh() async {
        guard let annotationSet, case .blocked(.noValidData) = notice else {
            return
        }
        await Persistence.store.allowFreshStart(
            documentHash: annotationSet.documentHash)
        savingAllowed = true
        notice = nil
    }

    // MARK: Relinking

    private func suggestRelink() async {
        await findRelinkCandidates()
        if canRelink, let best = relinkCandidates.first, isLikelyMatch(best) {
            notice = .relinkSuggested(best)
        }
    }

    /// What can be copied onto this PDF right now, with what other windows
    /// have yet to save.
    func refreshRelinkCandidates() async {
        await OpenDocuments.shared.flushAll()
        await findRelinkCandidates()
    }

    /// An edit like any other, so it can be undone and can't be overwritten
    /// by a save still pending, except that it's saved at once.
    func relink(from source: AnnotationStore.StoredSetSummary) async {
        await OpenDocuments.shared.flushAll()
        guard canRelink, let pdf else {
            notice = .error(
                """
                Annotations can only be relinked onto a PDF that has none, \
                and this one has some now.
                """)
            return
        }
        guard
            let saved = await Persistence.store.newestSet(
                documentHash: source.documentHash)
        else {
            notice = .error(
                """
                The annotations saved for “\(source.fileNameHint)” can't be \
                read any more.
                """)
            return
        }
        let pageBoxes = (0..<pdf.pageCount).map {
            pdf.page(at: $0)?.bounds(for: .cropBox) ?? .zero
        }
        guard
            let (edit, leftOut) = annotations.relinking(
                SidewaysBoxes.corrected(saved.annotations, in: pdf),
                pageBoxes: pageBoxes)
        else {
            notice = .error(
                """
                None of the annotations from “\(source.fileNameHint)” fit on \
                the pages of this PDF, so nothing was changed.
                """)
            return
        }
        annotationSet?.relinkedFrom = source.documentHash
        apply(edit)
        await flush()
        notice = .relinked(
            fileName: source.fileNameHint,
            annotationCount: edit.annotations.count, leftOut: leftOut)
    }

    /// A set saved for what looks like this same file comes first.
    private func findRelinkCandidates() async {
        guard let hash = annotationSet?.documentHash else { return }
        let others = await Persistence.store.storedSets(
            except: hash, document: pageIdentity?.documentID)
        relinkCandidates =
            others.filter(isLikelyMatch) + others.filter { !isLikelyMatch($0) }
    }

    private func isLikelyMatch(_ candidate: AnnotationStore.StoredSetSummary)
        -> Bool
    {
        guard let annotationSet else { return false }
        return candidate.fileNameHint == annotationSet.fileNameHint
            || (!annotationSet.pathHint.isEmpty
                && candidate.pathHint == annotationSet.pathHint)
    }

    // MARK: Editing

    func select(_ itemID: UUID?) {
        selection = itemID
    }

    var selectedAnnotations: [Annotation] {
        selection.map(annotations.item) ?? []
    }

    func addMarkup(
        _ kind: Annotation.Kind, lines: [(pageIndex: Int, rect: CGRect)],
        color: RGBAColor
    ) {
        apply(annotations.addingMarkup(kind, lines: lines, color: color))
    }

    /// Adds a note, selected, while its text is being written (see
    /// `finishingNote`).
    func beginNote(
        pageIndex: Int, iconRect: CGRect, anchorRects: [CGRect],
        color: RGBAColor
    ) -> UUID? {
        begin {
            $0.beginningNote(
                pageIndex: pageIndex, iconRect: iconRect,
                anchorRects: anchorRects, color: color)
        }
    }

    private func begin(_ make: ([Annotation]) -> (AnnotationEdit, UUID))
        -> UUID?
    {
        guard canEdit else { return nil }
        let (edit, id) = make(annotations)
        apply(edit)
        selection = id
        return id
    }

    func finishNote(_ id: UUID, text: String, isNew: Bool) {
        apply(annotations.finishingNote(id, text: text, isNew: isNew))
    }

    /// Adds a formula, selected, while its source is being written (see
    /// `finishingLaTeX`).
    func beginLaTeX(
        pageIndex: Int, bounds: CGRect, fontSize: Double, color: RGBAColor
    ) -> UUID? {
        begin {
            $0.beginningLaTeX(
                pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
                color: color)
        }
    }

    func finishLaTeX(
        _ id: UUID, source: String, expanded: String? = nil, fontSize: Double,
        size: CGSize, isNew: Bool, within page: PageFrame? = nil
    ) {
        apply(
            annotations.finishingLaTeX(
                id, source: source, expanded: expanded, fontSize: fontSize,
                size: size, isNew: isNew, within: page))
    }

    /// Adds a text box, selected, while its text is being written (see
    /// `finishingTextBox`).
    func beginTextBox(
        pageIndex: Int, bounds: CGRect, fontSize: Double, color: RGBAColor
    ) -> UUID? {
        begin {
            $0.beginningTextBox(
                pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
                color: color)
        }
    }

    func finishTextBox(
        _ id: UUID, text: String, expanded: String, fontSize: Double,
        size: CGSize, isNew: Bool, within page: PageFrame? = nil
    ) {
        apply(
            annotations.finishingTextBox(
                id, text: text, expanded: expanded, fontSize: fontSize,
                size: size, isNew: isNew, within: page))
    }

    func resizeTextBox(
        _ id: UUID, to size: CGSize, within page: PageFrame? = nil
    ) {
        apply(annotations.resizingTextBox(id, to: size, within: page))
    }

    func moveItem(_ itemID: UUID, by offset: CGSize) {
        apply(annotations.movingItem(itemID, by: offset))
    }

    func recolorItem(_ itemID: UUID, to color: RGBAColor) {
        apply(annotations.recoloringItem(itemID, to: color))
    }

    func deleteItem(_ itemID: UUID) {
        apply(annotations.deletingItem(itemID))
    }

    /// Puts back an earlier version's annotations; undoable, and saved as a
    /// new version.
    func restore(_ version: [Annotation]) {
        guard let pdf else { return }
        apply(
            annotations.restoringVersion(
                SidewaysBoxes.corrected(version, in: pdf)))
    }

    /// The one way annotations change: registers the undo (whose redo comes
    /// for free, since undoing goes through here too), bumps the revision and
    /// schedules a save.
    private func apply(_ edit: AnnotationEdit?) {
        guard let edit, canEdit, var set = annotationSet,
            edit.annotations != set.annotations
        else { return }
        let undoTo: [Annotation]? =
            switch edit.undo {
            case .toPrevious: set.annotations
            case .to(let annotations): annotations
            case .none: nil
            }
        set.annotations = edit.annotations
        set.revision += 1
        annotationSet = set
        switch notice {
        case .relinkSuggested?, .relinked?: notice = nil
        default: break
        }
        if let undoTo, let undoManager = undoManagerProvider?() {
            undoManager.registerUndo(withTarget: self) { session in
                MainActor.assumeIsolated {
                    session.apply(
                        AnnotationEdit(
                            annotations: undoTo, actionName: edit.actionName))
                }
            }
            undoManager.setActionName(edit.actionName)
        }
        autosaver.changed(set)
    }

    // MARK: Export

    var quickExportURL: URL? {
        currentFileURL.map(PDFExporter.quickExportURL(for:))
    }

    func quickExport() async {
        guard let url = quickExportURL else { return }
        await export(to: url)
    }

    /// Exports run one after another, and are off the main thread, so closing
    /// the window or quitting waits for them (see `finishExports`).
    func export(to url: URL) async {
        let earlier = exportTask
        let task = Task {
            await earlier?.value
            await writeCopy(to: url)
        }
        exportTask = task
        await task.value
    }

    func finishExports() async {
        await exportTask?.value
    }

    /// Saves, then writes a copy of the PDF with the annotations to `url`
    /// (never the original), and shows a confirmation that goes away by
    /// itself.
    private func writeCopy(to url: URL) async {
        await flush()
        let annotations = annotations
        notice = .exporting(url)
        do {
            try await PDFExporter.export(
                original: data, annotations: annotations, to: url,
                originalURL: currentFileURL)
            let id = UUID()
            notice = .exported(url, annotationCount: annotations.count, id: id)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if case .exported(_, _, id)? = self?.notice {
                    self?.notice = nil
                }
            }
        } catch {
            notice = .error(
                """
                Couldn't export “\(url.lastPathComponent)”: \
                \(error.localizedDescription)
                """
            )
        }
    }

    // MARK: Pages

    /// Page changes run one after another, undone ones included, and nothing
    /// else can change meanwhile. A failure is shown, and the task returns
    /// false.
    func queuePageChange(
        _ change: @escaping @MainActor () async throws -> Void
    ) -> Task<Bool, Never> {
        let earlier = pageTask
        isChangingPages = true
        let task = Task {
            _ = await earlier?.value
            isChangingPages = true
            defer { isChangingPages = false }
            do {
                try await change()
                return true
            } catch {
                notice = .error(
                    """
                    The pages of “\(fileName)” weren't changed. \
                    \(error.localizedDescription)
                    """
                )
                return false
            }
        }
        pageTask = task
        return task
    }

    /// Lets a page change being written finish, so closing the window or
    /// quitting doesn't cut it short.
    func finishPageChanges() async {
        while isChangingPages, let pageTask { _ = await pageTask.value }
    }

    /// A page change has been written: shows the new pages, and then the
    /// annotations that go with them.
    func showPages(
        _ data: Data, identity: PageIdentity, annotations: AnnotationSet,
        newIndices: [Int?]
    ) {
        self.data = data
        pdf = PDFDocument(data: data)
        pageIdentity = identity
        if case .relinkSuggested? = notice { notice = nil }
        onPagesChanged?(newIndices)
        annotationSet = annotations
        OpenDocuments.shared.pagesChanged(in: self)
    }
}
