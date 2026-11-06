import MathPDFCore
import MathPDFRendering
import PDFKit

/// Moving, deleting and pasting pages, the one thing that changes the PDF
/// file, and copying them out.
extension DocumentSession {
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
        canWrite && fileURL != nil
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
        await OpenDocuments.shared.flushSessions(showing: target.hash)
        guard !autosaver.hasUnsavedChanges else {
            throw PageChangeError.annotationsNotSaved
        }
        guard var set = annotationSet, set.documentHash == current.hash,
            let url = currentFileURL, let documentID = pageIdentity?.documentID
        else { throw PageChangeError.outOfStep }
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
        let saved = try await Persistence.store.saveAsNewest(set)
        let document = fileDocumentProvider?()
        let presenter = PDFFileWriter.Presenter(document)
        try await Task.detached(priority: .userInitiated) {
            try PDFFileWriter.replace(url, with: target.data, by: presenter)
        }.value
        document?.fileModificationDate =
            try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        showPages(
            target.data, identity: identity, annotations: saved,
            newIndices: newIndices)
    }
}
