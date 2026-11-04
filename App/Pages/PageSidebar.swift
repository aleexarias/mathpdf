import AppKit
import PDFKit
import SwiftUI

/// The Pages sidebar: a thumbnail per page, following the page on screen.
/// ⌘- and ⇧-click select several pages. Dragging them reorders them, and
/// dragging them to another window's sidebar copies them there (⌥-drag copies
/// within one PDF). Cut, Copy, Paste and Delete work on the selected pages,
/// from the keyboard, the Edit menu or the right-click menu.
@MainActor
final class PageSidebar: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSDraggingSource
{
    let scrollView = NSScrollView()
    private let tableView = PageTableView()
    private weak var viewer: Viewer?
    /// The thumbnails of the rows on screen; dropped as rows leave it.
    private var thumbnails: [Int: NSImage] = [:]
    private var pendingThumbnails: Set<Int> = []
    /// Goes up with each reload, so thumbnails asked for before it are
    /// dropped.
    private var generation = 0
    private var lastWidth: CGFloat = 0
    /// Set while the selection is changed in code, so it doesn't go to the
    /// page.
    private var isSelectingInCode = false

    private static let cellID = NSUserInterfaceItemIdentifier("page")

    init(viewer: Viewer) {
        self.viewer = viewer
        super.init()
        let column = NSTableColumn(identifier: Self.cellID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.sidebar = self
        tableView.registerForDraggedTypes([.draggedPages])
        tableView.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // Thumbnails are as wide as the sidebar, so row heights follow it.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(widthChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView)
    }

    // MARK: Updating

    /// Every page again, after the document changed.
    func reload() {
        thumbnails.removeAll()
        pendingThumbnails.removeAll()
        generation += 1
        isSelectingInCode = true
        tableView.reloadData()
        isSelectingInCode = false
        if let viewer { select([viewer.pageIndex]) }
    }

    func pagesRedrawn(_ pages: [Int]) {
        for page in pages {
            if cell(page) != nil {
                requestThumbnail(page)
            } else {
                thumbnails[page] = nil
            }
        }
    }

    /// The selection follows the page on screen, unless several pages are
    /// selected.
    func showCurrentPage() {
        guard let viewer, tableView.selectedRowIndexes.count <= 1,
            tableView.selectedRow != viewer.pageIndex
        else { return }
        select([viewer.pageIndex])
    }

    func select(_ rows: IndexSet) {
        let rows = rows.filteredIndexSet { $0 < tableView.numberOfRows }
        isSelectingInCode = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isSelectingInCode = false
        if let first = rows.first { tableView.scrollRowToVisible(first) }
    }

    @objc private func widthChanged() {
        let width = scrollView.contentView.bounds.width
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(0..<tableView.numberOfRows))
        }
    }

    // MARK: Thumbnails

    /// The row's cell, if the table has one: rows in view, and a few more.
    private func cell(_ row: Int) -> PageCell? {
        tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? PageCell
    }

    private var rowWidth: CGFloat {
        max(scrollView.contentView.bounds.width, 60)
    }

    private func pageSize(_ row: Int) -> CGSize {
        guard let page = viewer?.pdfView.document?.page(at: row) else {
            return CGSize(width: 612, height: 792)
        }
        let box = page.bounds(for: .cropBox).size
        let size =
            page.rotation % 180 == 0
            ? box : CGSize(width: box.height, height: box.width)
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// Drawn a moment later, so scrolling through a long document doesn't
    /// wait for each page. The old thumbnail stays until the new one is
    /// ready.
    private func requestThumbnail(_ row: Int) {
        guard pendingThumbnails.insert(row).inserted else { return }
        let generation = generation
        Task { [weak self] in
            guard let self, self.generation == generation,
                self.pendingThumbnails.remove(row) != nil
            else { return }
            // One scrolled away is drawn when it's back in view.
            guard let cell = self.cell(row),
                let page = self.viewer?.pdfView.document?.page(at: row)
            else {
                self.thumbnails[row] = nil
                return
            }
            let size = PageCell.thumbnailSize(
                self.pageSize(row), width: self.rowWidth)
            let image = page.thumbnail(
                of: CGSize(width: size.width * 2, height: size.height * 2),
                for: .cropBox)
            self.thumbnails[row] = image
            cell.thumbnail.image = image
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        viewer?.pdfView.document?.pageCount ?? 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        PageCell.height(for: pageSize(row), width: rowWidth)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int)
        -> NSTableRowView?
    {
        PageRowView()
    }

    func tableView(
        _ tableView: NSTableView, didRemove rowView: NSTableRowView,
        forRow row: Int
    ) {
        if row >= 0 { thumbnails[row] = nil }
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil)
            as? PageCell ?? PageCell(identifier: Self.cellID)
        cell.pageSize = pageSize(row)
        cell.number.stringValue = "\(row + 1)"
        cell.thumbnail.image = thumbnails[row]
        if thumbnails[row] == nil { requestThumbnail(row) }
        return cell
    }

    /// Goes to the page clicked last, or added to the selection last.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard !isSelectingInCode, let viewer, row >= 0, row != viewer.pageIndex
        else { return }
        viewer.go(toPage: row)
    }

    // MARK: Editing

    private var selectedPages: [Int] { Array(tableView.selectedRowIndexes) }

    var canCopy: Bool {
        !selectedPages.isEmpty && viewer?.session.canCopyPages == true
    }

    /// A PDF needs at least one page.
    var canDelete: Bool {
        !selectedPages.isEmpty && selectedPages.count < tableView.numberOfRows
            && viewer?.canChangePages == true
    }

    var canCut: Bool { canCopy && canDelete }

    var canPaste: Bool { viewer?.canPastePages(fromOtherApps: true) == true }

    func copySelection() {
        guard let viewer, !selectedPages.isEmpty else { return NSSound.beep() }
        let pages = selectedPages
        Task { await viewer.copyPages(pages) }
    }

    func cutSelection() {
        guard canCut, let viewer else {
            return refuse(copying: !canCopy)
        }
        let pages = selectedPages
        Task { await viewer.cutPages(pages) }
    }

    func deleteSelection() {
        guard canDelete, let viewer else { return refuse(copying: false) }
        let pages = selectedPages
        Task { await viewer.deletePages(pages) }
    }

    /// After the last selected page, or at the end.
    func paste() {
        guard canPaste, let viewer else { return refuse(copying: false) }
        let index =
            tableView.selectedRowIndexes.last.map { $0 + 1 }
            ?? tableView.numberOfRows
        Task {
            await viewer.pasteFromClipboard(at: index, fromOtherApps: true)
        }
    }

    /// Nothing selected, or every page, is just a beep.
    private func refuse(copying: Bool) {
        guard let viewer, !selectedPages.isEmpty,
            selectedPages.count < tableView.numberOfRows
        else { return NSSound.beep() }
        viewer.refusePageChange(copying: copying)
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
            tableView.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        func add(
            _ title: String, enabled: Bool, _ action: @escaping () -> Void
        ) {
            let item = ClosureMenuItem(title, handler: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Cut", enabled: canCut) { [weak self] in self?.cutSelection() }
        add("Copy", enabled: canCopy) { [weak self] in self?.copySelection() }
        add("Paste", enabled: canPaste) { [weak self] in self?.paste() }
        menu.addItem(.separator())
        let count = selectedPages.count
        add(
            count > 1 ? "Delete \(count) Pages" : "Delete Page",
            enabled: canDelete
        ) { [weak self] in self?.deleteSelection() }
    }

    // MARK: Dragging

    /// Starts dragging `rows` as one item. The picture is placed beside the
    /// pointer before the drag starts, so it appears there instead of
    /// sliding over from the thumbnails.
    func beginDrag(_ rows: IndexSet, with event: NSEvent) {
        guard let viewer, let first = rows.first,
            let item = DraggedPages.makeItem(
                pages: Array(rows), of: viewer.session)
        else { return }
        let picture = PageDragImage(
            label: rows.count == 1
                ? "Page \(first + 1)" : "\(rows.count) Pages",
            stacked: rows.count > 1)
        let point = tableView.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // beside the pointer, clear of the arrow (the table is flipped, so y
        // grows downwards)
        dragging.setDraggingFrame(
            CGRect(
                origin: CGPoint(x: point.x + 12, y: point.y + 2),
                size: picture.image.size),
            contents: picture.image)
        let session = tableView.beginDraggingSession(
            with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// Pages go only to mathpdf windows, which copy them from this one.
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : []
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard viewer?.canChangePages == true,
            let dragged = DraggedPages(from: info.draggingPasteboard)
        else { return [] }
        // Thumbnails are tall, so a drop on one goes before or after it,
        // whichever half it's on.
        if dropOperation == .on {
            let point = tableView.convert(info.draggingLocation, from: nil)
            let after = point.y > tableView.rect(ofRow: row).midY
            tableView.setDropRow(after ? row + 1 : row, dropOperation: .above)
        }
        return isMove(dragged, info) ? .move : .copy
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let viewer,
            let dragged = DraggedPages(from: info.draggingPasteboard)
        else { return false }
        let move = isMove(dragged, info)
        Task {
            if move {
                await viewer.movePages(dragged.pages, to: row)
            } else {
                await viewer.insert(dragged, at: row)
            }
        }
        return true
    }

    /// Pages dragged within one sidebar move, unless ⌥ is held.
    private func isMove(_ dragged: DraggedPages, _ info: any NSDraggingInfo)
        -> Bool
    {
        dragged.session === viewer?.session
            && info.draggingSourceOperationMask.contains(.move)
    }
}

/// Hosts a window's page sidebar, which its `Viewer` owns, so the selection
/// survives switching to the Annotations list and back.
struct PageSidebarView: NSViewRepresentable {
    let sidebar: PageSidebar

    func makeNSView(context: Context) -> NSScrollView { sidebar.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
