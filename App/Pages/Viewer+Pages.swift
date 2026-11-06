import AppKit
import MathPDFCore
import MathPDFRendering

/// Moving, deleting, copying and pasting pages, from the sidebar, the menus
/// and the page view. Each finishes what's being typed first, and leaves the
/// pages it touched selected in the sidebar.
extension Viewer {
    var canChangePages: Bool { session.canChangePages }

    func canPastePages(fromOtherApps: Bool) -> Bool {
        session.canChangePages
            && PageClipboard.hasPages(fromOtherApps: fromOtherApps)
    }

    @discardableResult
    func copyPages(_ pages: [Int]) async -> Bool {
        guard session.canCopyPages else {
            refusePageChange(copying: true)
            return false
        }
        guard editor.finishEditing(),
            let copied = await session.copyPages(pages)
        else { return false }
        PageClipboard.write(copied)
        return true
    }

    func cutPages(_ pages: [Int]) async {
        guard pages.count < pageCount, await copyPages(pages) else { return }
        await deletePages(pages, actionName: Self.name("Cut", pages.count))
    }

    func deletePages(_ pages: [Int], actionName: String? = nil) async {
        // a PDF needs at least one page
        guard !pages.isEmpty, pages.count < pageCount else {
            return NSSound.beep()
        }
        guard readyToChangePages(),
            await session.changePages(
                .deleting(pages, pageCount: pageCount),
                actionName: actionName ?? Self.name("Delete", pages.count))
        else { return }
        sidebar.select([min(pages.min() ?? 0, pageCount - 1)])
    }

    func movePages(_ pages: [Int], to destination: Int) async {
        let before = pageCount
        let arrangement = PageArrangement.moving(
            pages, to: destination, pageCount: before)
        guard !arrangement.changesNothing(pageCount: before),
            readyToChangePages(),
            await session.changePages(
                arrangement, actionName: Self.name("Move", pages.count))
        else { return }
        let newIndices = arrangement.newIndices(pageCount: before)
        sidebar.select(IndexSet(pages.compactMap { newIndices[$0] }))
    }

    /// Pastes pages copied in mathpdf, or with `fromOtherApps` any PDF, before
    /// the page now at `index`.
    func pasteFromClipboard(at index: Int, fromOtherApps: Bool) async {
        guard let copied = PageClipboard.read(fromOtherApps: fromOtherApps)
        else { return NSSound.beep() }
        await paste(copied, at: index)
    }

    /// Pages dragged from a sidebar: another window's, or this one's with ⌥.
    func insert(_ dragged: DraggedPages, at index: Int) async {
        guard readyToChangePages(),
            let copied = await dragged.session.copyPages(dragged.pages)
        else { return }
        await paste(copied, at: index)
    }

    private func paste(_ copied: CopiedPages, at index: Int) async {
        let index = min(max(index, 0), pageCount)
        guard readyToChangePages(),
            await session.changePages(
                .inserting(copied.pageCount, at: index, pageCount: pageCount),
                pasting: copied,
                actionName: Self.name("Paste", copied.pageCount))
        else { return }
        go(toPage: index)
        sidebar.select(IndexSet(index..<index + copied.pageCount))
    }

    /// Page changes rewrite the PDF, so what's being typed is finished first.
    private func readyToChangePages() -> Bool {
        guard session.canChangePages else {
            refusePageChange(copying: false)
            return false
        }
        return editor.finishEditing()
    }

    /// Says why, when it's the PDF's security settings; otherwise beeps.
    func refusePageChange(copying: Bool) {
        let allowed =
            copying ? PageAssembler.canCopyPages : PageAssembler.canChangePages
        guard let pdf = session.pdf, !allowed(pdf) else {
            return NSSound.beep()
        }
        let action = copying ? "copying" : "changing"
        session.notice = .error(
            """
            The security settings of “\(session.fileName)” don't allow \
            \(action) its pages.
            """
        )
    }

    private static func name(_ verb: String, _ count: Int) -> String {
        count == 1 ? "\(verb) Page" : "\(verb) Pages"
    }
}
