import MathPDFCore
import MathPDFRendering
import Observation
import PDFKit

/// One open PDF: the read-only document, its annotations, and how they are
/// saved.
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

    let pdf: PDFDocument?
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
    /// The PDF's bytes, as opened. Never changed or written anywhere.
    @ObservationIgnored let data: Data

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

    /// Annotations can't be changed while loading, or while saving is blocked.
    var canEdit: Bool { phase == .ready && savingAllowed }

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
