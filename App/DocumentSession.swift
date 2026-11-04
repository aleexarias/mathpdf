import MathPDFCore
import MathPDFRendering
import Observation
import PDFKit

/// One open PDF: the document, its annotations, and how they are saved.
/// Annotations never change the PDF; moving, deleting and pasting pages does
/// (the Pages section).
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
        case relinked(fileName: String, annotationCount: Int)
        /// `id` tells one export's confirmation from the next, so each goes
        /// away on its own time.
        case exported(URL, annotationCount: Int, id: UUID)
        case error(String)
    }

    /// Tells this window's pages apart from another's when they're dragged.
    let id = UUID()
    private(set) var pdf: PDFDocument?
    let fileURL: URL?
    let autosaver = Autosaver(store: Persistence.store)
    private(set) var phase: Phase = .loading
    private(set) var annotationSet: AnnotationSet? {
        didSet { onChange?() }
    }
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
    /// The last page change queued (see `queuePageChange`).
    @ObservationIgnored private var pageTask: Task<Bool, Never>?

    init(data: Data, fileURL: URL?) {
        self.data = data
        self.fileURL = fileURL
        pdf = PDFDocument(data: data)
        if pdf == nil {
            phase = .failed("This file couldn't be opened as a PDF.")
        }
    }

    var fileName: String { fileURL?.lastPathComponent ?? "Untitled.pdf" }

    var dataFolderURL: URL? {
        annotationSet.map { Persistence.store.folderURL($0.documentHash) }
    }

    var annotations: [Annotation] { annotationSet?.annotations ?? [] }

    /// Annotations can't be changed while loading, while saving is blocked, or
    /// while pages are being written.
    var canEdit: Bool { phase == .ready && savingAllowed && !isChangingPages }

    enum SaveStatus { case saved, edited, failed }

    /// For the title bar: "Edited" while changes aren't on disk yet.
    var saveStatus: SaveStatus {
        guard autosaver.hasUnsavedChanges else { return .saved }
        return autosaver.lastError == nil ? .edited : .failed
    }

    /// Relinking replaces this PDF's annotations, so it's only offered while
    /// there are none.
    var canRelink: Bool {
        canEdit && annotations.isEmpty && !relinkCandidates.isEmpty
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

        switch await Persistence.store.load(documentHash: hash) {
        case .fresh:
            annotationSet = blank
            savingAllowed = true
            await findRelinkCandidates(for: blank)
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
        let stored = await Persistence.store.pageIdentity(documentHash: hash)
        pageIdentity =
            stored?.pageIDs.count == pdf.pageCount
            ? stored : PageIdentity(pageCount: pdf.pageCount)
        phase = .ready
        SaveCoordinator.shared.register(self)
    }

    func flush() async {
        await autosaver.flush()
    }

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

    func relink(from source: AnnotationStore.StoredSetSummary) async {
        guard canRelink, let current = annotationSet else { return }
        do {
            let relinked = try await Persistence.store.relink(
                from: source.documentHash, to: current)
            annotationSet = relinked
            relinkCandidates.removeAll()
            undoManagerProvider?()?.removeAllActions(withTarget: self)
            notice = .relinked(
                fileName: source.fileNameHint,
                annotationCount: relinked.annotations.count)
        } catch {
            notice = .error(
                "Couldn't relink annotations: \(error.localizedDescription)")
        }
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
        guard canEdit else { return nil }
        let (edit, id) = annotations.beginningNote(
            pageIndex: pageIndex, iconRect: iconRect, anchorRects: anchorRects,
            color: color)
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
        guard canEdit else { return nil }
        let (edit, id) = annotations.beginningLaTeX(
            pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
            color: color)
        apply(edit)
        selection = id
        return id
    }

    func finishLaTeX(
        _ id: UUID, source: String, fontSize: Double, size: CGSize,
        isNew: Bool, within page: CGRect? = nil
    ) {
        apply(
            annotations.finishingLaTeX(
                id, source: source, fontSize: fontSize, size: size,
                isNew: isNew, within: page))
    }

    /// Adds a text box, selected, while its text is being written (see
    /// `finishingTextBox`).
    func beginTextBox(
        pageIndex: Int, bounds: CGRect, fontSize: Double, color: RGBAColor
    ) -> UUID? {
        guard canEdit else { return nil }
        let (edit, id) = annotations.beginningTextBox(
            pageIndex: pageIndex, bounds: bounds, fontSize: fontSize,
            color: color)
        apply(edit)
        selection = id
        return id
    }

    func finishTextBox(
        _ id: UUID, text: String, fontSize: Double, size: CGSize, isNew: Bool,
        within page: CGRect? = nil
    ) {
        apply(
            annotations.finishingTextBox(
                id, text: text, fontSize: fontSize, size: size, isNew: isNew,
                within: page))
    }

    func resizeTextBox(_ id: UUID, to size: CGSize, within page: CGRect? = nil)
    {
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

    // MARK: Export

    var quickExportURL: URL? { fileURL.map(PDFExporter.quickExportURL(for:)) }

    func quickExport() async {
        guard let url = quickExportURL else { return }
        await export(to: url)
    }

    /// Saves, then writes a copy of the PDF with the annotations to `url`
    /// (never the original), and shows a confirmation that goes away by
    /// itself.
    func export(to url: URL) async {
        await flush()
        do {
            try PDFExporter.export(
                original: data, annotations: annotations, to: url,
                originalURL: fileURL)
            let id = UUID()
            notice = .exported(url, annotationCount: annotations.count, id: id)
            try? await Task.sleep(for: .seconds(8))
            if case .exported(_, _, id)? = notice { notice = nil }
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

    /// The PDF and its annotations at one point, before or after a page
    /// change.
    private struct PagesState: Sendable {
        let data: Data
        let hash: String
        let pageIDs: [UUID]
        let annotations: [Annotation]
    }

    private enum PageChangeError: LocalizedError {
        case annotationsNotSaved
        case outOfStep
        case damagedPageOrder

        var errorDescription: String? {
            switch self {
            case .annotationsNotSaved:
                "The annotations couldn't be saved first."
            case .outOfStep: "An earlier page change didn't go through."
            case .damagedPageOrder:
                "The copy kept of those pages can't be read."
            }
        }
    }

    var canCopyPages: Bool {
        phase == .ready && !isChangingPages
            && pdf.map(PageAssembler.canCopyPages) == true
    }

    /// Changing pages rewrites the PDF file itself.
    var canChangePages: Bool {
        canEdit && fileURL != nil
            && pdf.map(PageAssembler.canChangePages) == true
    }

    /// `pages`, in that order, with their annotations.
    func copyPages(_ pages: [Int]) async -> CopiedPages? {
        guard canCopyPages, !pages.isEmpty else { return nil }
        let data = data
        do {
            let pdf = try await Task.detached(priority: .userInitiated) {
                try PageAssembler.extract(pages, from: data)
            }.value
            return CopiedPages(
                pdf: pdf, pageCount: pages.count,
                annotations: annotations.onPages(pages))
        } catch {
            notice = .error(
                "Couldn't copy the pages: \(error.localizedDescription)")
            return nil
        }
    }

    /// Moves, deletes or pastes pages, taking their annotations along, and
    /// writes the PDF. Undoable.
    @discardableResult
    func changePages(
        _ arrangement: PageArrangement, pasting copied: CopiedPages? = nil,
        actionName: String
    ) async -> Bool {
        guard let set = annotationSet, !arrangement.pages.isEmpty,
            !arrangement.changesNothing(pageCount: set.pageCount)
        else { return false }
        return await runPageChange(
            actionName,
            newIndices: arrangement.newIndices(pageCount: set.pageCount)
        ) { current in
            let data = try PageAssembler.arrange(
                current.data, as: arrangement, pasted: copied?.pdf)
            return PagesState(
                data: PDFFileWriter.mappedCopy(of: data),
                hash: sha256Hex(data),
                pageIDs: arrangement.pageIDs(from: current.pageIDs),
                annotations: current.annotations.arranged(
                    for: arrangement, pasted: copied?.annotations ?? []))
        }
    }

    /// Goes back to an earlier page order, from the version history, keeping
    /// today's annotations: they follow their pages, and a page deleted since
    /// comes back with `earlier`, the annotations it had. Undoable.
    @discardableResult
    func restorePages(
        _ order: AnnotationStore.PageOrder, earlier: [Annotation]
    ) async -> Bool {
        guard let url = order.pdfURL, let currentIDs = pageIdentity?.pageIDs
        else { return false }
        let pages = order.identity.pageIDs
        return await runPageChange(
            "Restore Pages",
            newIndices: currentIDs.map { pages.firstIndex(of: $0) }
        ) { current in
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            guard sha256Hex(data) == order.documentHash,
                PDFDocument(data: data)?.pageCount == pages.count
            else { throw PageChangeError.damagedPageOrder }
            return PagesState(
                data: data, hash: order.documentHash, pageIDs: pages,
                annotations: current.annotations.restoringPages(
                    pages, from: current.pageIDs, earlier: earlier))
        }
    }

    /// Works out the new PDF and annotations from the current ones, off the
    /// main thread, writes them, and registers the undo.
    private func runPageChange(
        _ actionName: String, newIndices: [Int?],
        target makeTarget:
            @escaping @Sendable (PagesState) throws ->
            PagesState
    ) async -> Bool {
        guard canChangePages, let set = annotationSet,
            let identity = pageIdentity
        else { return false }
        let current = PagesState(
            data: data, hash: set.documentHash, pageIDs: identity.pageIDs,
            annotations: set.annotations)
        return await queuePageChange {
            let target = try await Task.detached(priority: .userInitiated) {
                try makeTarget(current)
            }.value
            try await self.switchPages(
                from: current, to: target, newIndices: newIndices)
            self.registerPageUndo(
                back: current, from: target,
                newIndices: PageArrangement.inverse(
                    of: newIndices, count: target.pageIDs.count),
                actionName: actionName)
        }.value
    }

    /// Page changes run one after another, undone ones included, and nothing
    /// else can change meanwhile. A failure is shown, and the task returns
    /// false.
    private func queuePageChange(
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
                showPageChangeError(error)
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

    /// Undoing goes back to `previous`. The redo is registered as soon as the
    /// undo starts, as the undo manager expects; if the undo then fails, the
    /// undo history is cleared rather than left out of step.
    private func registerPageUndo(
        back previous: PagesState, from current: PagesState,
        newIndices: [Int?], actionName: String
    ) {
        guard let undoManager = undoManagerProvider?() else { return }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.registerPageUndo(
                    back: current, from: previous,
                    newIndices: PageArrangement.inverse(
                        of: newIndices, count: current.pageIDs.count),
                    actionName: actionName)
                _ = session.queuePageChange {
                    do {
                        try await session.switchPages(
                            from: current, to: previous,
                            newIndices: newIndices)
                    } catch {
                        session.undoManagerProvider?()?.removeAllActions(
                            withTarget: session)
                        throw error
                    }
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    /// Replaces `current` with `target`: first the annotations, under the new
    /// PDF's hash, then the PDF file. A crash in between leaves the old PDF,
    /// whose annotations are still stored under its own hash.
    private func switchPages(
        from current: PagesState, to target: PagesState, newIndices: [Int?]
    ) async throws {
        await flush()
        guard !autosaver.hasUnsavedChanges else {
            throw PageChangeError.annotationsNotSaved
        }
        guard var set = annotationSet, set.documentHash == current.hash,
            let openedURL = fileURL, let documentID = pageIdentity?.documentID
        else { throw PageChangeError.outOfStep }
        let document = fileDocumentProvider?()
        // The document follows the file if it's moved while open.
        let url = document?.fileURL ?? openedURL
        try await Task.detached(priority: .userInitiated) {
            try PDFFileWriter.checkUnchanged(url, hash: current.hash)
        }.value
        // The pages being left are kept, for the version history.
        set = try await Persistence.store.leavePages(
            set,
            identity: PageIdentity(
                documentID: documentID, pageIDs: current.pageIDs),
            pdf: current.data)
        let identity = PageIdentity(
            documentID: documentID, pageIDs: target.pageIDs)
        try await Persistence.store.savePageIdentity(
            identity, documentHash: target.hash)

        set.documentHash = target.hash
        set.pageCount = target.pageIDs.count
        set.annotations = target.annotations
        let saved = try await Persistence.store.saveAfterPageChange(set)
        let presenter = PDFFileWriter.Presenter(document)
        try await Task.detached(priority: .userInitiated) {
            try PDFFileWriter.replace(url, with: target.data, by: presenter)
        }.value
        document?.fileModificationDate =
            try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        data = target.data
        pdf = PDFDocument(data: target.data)
        pageIdentity = identity
        relinkCandidates.removeAll()
        if case .relinkSuggested? = notice { notice = nil }
        onPagesChanged?(newIndices)
        annotationSet = saved
        if let selection,
            !saved.annotations.contains(where: { $0.itemID == selection })
        {
            self.selection = nil
        }
    }

    private func showPageChangeError(_ error: any Error) {
        notice = .error(
            """
            The pages of “\(fileName)” weren't changed. \
            \(error.localizedDescription)
            """
        )
    }

    /// Puts back an earlier version's annotations; undoable, and saved as a
    /// new version.
    func restore(_ version: [Annotation]) {
        apply(annotations.restoringVersion(version))
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
        if let selection,
            !edit.annotations.contains(where: { $0.itemID == selection })
        {
            self.selection = nil
        }
        autosaver.changed(set)
    }

    private func findRelinkCandidates(for blank: AnnotationSet) async {
        let others = await Persistence.store.storedSets().filter {
            $0.documentHash != blank.documentHash
        }
        func isLikelyMatch(_ candidate: AnnotationStore.StoredSetSummary)
            -> Bool
        {
            candidate.fileNameHint == blank.fileNameHint
                || (!blank.pathHint.isEmpty
                    && candidate.pathHint == blank.pathHint)
        }
        relinkCandidates =
            others.filter(isLikelyMatch) + others.filter { !isLikelyMatch($0) }
        if let best = relinkCandidates.first, isLikelyMatch(best),
            best.annotationCount > 0
        {
            notice = .relinkSuggested(best)
        }
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
}
