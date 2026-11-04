import AppKit

/// Sends Cut, Copy, Paste and Delete, and the Delete key, to the sidebar.
final class PageTableView: NSTableView {
    weak var sidebar: PageSidebar?

    /// Plain clicks and drags on a page are handled here. A click selects
    /// the page straight away; a click on one of several selected pages
    /// selects just that one as soon as the button comes up. A drag takes the
    /// selected pages, or the page under the pointer if it wasn't selected.
    /// ⌘-, ⇧- and ⌃-clicks, and clicks between pages, are NSTableView's.
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0,
            event.modifierFlags.isDisjoint(with: [.command, .shift, .control]),
            let window
        else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        let wasSelected = selectedRowIndexes.contains(row)
        if !wasSelected {
            selectRowIndexes([row], byExtendingSelection: false)
        }
        while let next = window.nextEvent(
            matching: [.leftMouseUp, .leftMouseDragged])
        {
            if next.type == .leftMouseUp {
                if wasSelected, selectedRowIndexes.count > 1 {
                    selectRowIndexes([row], byExtendingSelection: false)
                }
                return
            }
            let start = event.locationInWindow
            let now = next.locationInWindow
            if hypot(now.x - start.x, now.y - start.y) >= 3 {
                sidebar?.beginDrag(selectedRowIndexes, with: next)
                return
            }
        }
    }

    @objc func cut(_ sender: Any?) { sidebar?.cutSelection() }
    @objc func copy(_ sender: Any?) { sidebar?.copySelection() }
    @objc func paste(_ sender: Any?) { sidebar?.paste() }
    @objc func delete(_ sender: Any?) { sidebar?.deleteSelection() }

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        guard let sidebar else { return false }
        switch item.action {
        case #selector(cut(_:)): return sidebar.canCut
        case #selector(copy(_:)): return sidebar.canCopy
        case #selector(paste(_:)): return sidebar.canPaste
        case #selector(delete(_:)): return sidebar.canDelete
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .delete?, .deleteForward?: sidebar?.deleteSelection()
        default: super.keyDown(with: event)
        }
    }
}

/// Each selected page gets a highlight of its own, with a gap to the next,
/// so a run of selected pages doesn't merge into one block.
final class PageRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color =
            isEmphasized
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        let inset = PageCell.highlightInset
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset.width, dy: inset.height),
            xRadius: 8, yRadius: 8
        ).fill()
    }
}

/// A page's thumbnail with its number under it.
final class PageCell: NSTableCellView {
    let thumbnail = NSImageView()
    let number = NSTextField(labelWithString: "")
    var pageSize = CGSize(width: 612, height: 792) {
        didSet { needsLayout = true }
    }

    /// Between the row's edges and its highlight.
    static let highlightInset = CGSize(width: 10, height: 4)
    /// Between the highlight's edges and the thumbnail.
    private static let padding: CGFloat = 8
    private static let numberHeight: CGFloat = 16
    /// So that landscape and portrait pages look about the same size.
    private static let maxThumbnailHeight: CGFloat = 130

    /// At most three quarters of the sidebar's width.
    static func thumbnailSize(_ page: CGSize, width: CGFloat) -> CGSize {
        let room = width - 2 * (highlightInset.width + padding)
        let width = max(min(room, width * 0.75), 20)
        let scale = min(width / page.width, maxThumbnailHeight / page.height)
        return CGSize(width: page.width * scale, height: page.height * scale)
    }

    private static var top: CGFloat { highlightInset.height + padding }

    static func height(for page: CGSize, width: CGFloat) -> CGFloat {
        top + thumbnailSize(page, width: width).height + 4 + numberHeight
            + highlightInset.height + padding / 2
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        thumbnail.imageScaling = .scaleAxesIndependently
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = NSColor.white.cgColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        thumbnail.shadow = shadow
        number.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        number.textColor = .secondaryLabelColor
        number.alignment = .center
        addSubview(thumbnail)
        addSubview(number)
        // so the number turns white on a selected row
        textField = number
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var size = Self.thumbnailSize(pageSize, width: bounds.width)
        let room =
            bounds.height - Self.height(for: pageSize, width: bounds.width)
            + size.height
        if size.height > room, room > 0 {
            size = CGSize(
                width: size.width * room / size.height, height: room)
        }
        thumbnail.frame =
            CGRect(
                x: (bounds.width - size.width) / 2, y: Self.top,
                width: size.width, height: size.height
            ).integral
        number.frame = CGRect(
            x: 0, y: thumbnail.frame.maxY + 4, width: bounds.width,
            height: Self.numberHeight)
    }
}
