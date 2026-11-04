import AppKit
import PDFKit
import SwiftUI

/// Links the two previews, which can show different pages. Each scrolls by
/// itself with the mouse over it, and one scroll bar moves both by the same
/// amount; one already at its top or end stays there while the other goes
/// on. The bar works as if the two were one document: at its top both are
/// at theirs, at its bottom both are at their ends. Both show the same zoom;
/// the leader fits the pages to its width and the follower takes its zoom.
@MainActor
final class PreviewScrollLink: NSObject {
    enum Role { case leader, follower }

    private weak var leader: PDFView?
    private weak var follower: PDFView?
    private weak var scroller: NSScroller?
    /// Set while a preview is being changed to match the other, so that
    /// isn't echoed back.
    private var isMatching = false
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    /// The page a new preview opens at, once it's laid out.
    private var pendingStart: [ObjectIdentifier: PDFPage] = [:]

    /// Where a preview is scrolled to, in page units from the top of its
    /// pages (the same at any zoom), and how far it can go.
    private struct Position {
        var offset: CGFloat
        let range: CGFloat
        let visible: CGFloat
    }

    /// Shows a version's document. The preview stays at the same distance
    /// from the top, so switching versions doesn't move anything. The first
    /// time, it opens at `startPage`.
    func show(
        _ document: PDFDocument, in view: PDFView, role: Role, startPage: Int
    ) {
        switch role {
        case .leader: leader = view
        case .follower: follower = view
        }
        let kept = view.document == nil ? nil : position(of: view)?.offset
        isMatching = true
        view.document = document
        (view as? PreviewPDFView)?.hideScrollBars()
        view.layoutDocumentView()
        observe(view)
        isMatching = false
        matchZoom()
        if let kept {
            scroll(view, to: kept)
        } else if let page = document.page(
            at: min(startPage, document.pageCount - 1))
        {
            // PDFKit doesn't scroll a view that hasn't been given a size yet.
            pendingStart[ObjectIdentifier(view)] = page
            startIfReady(view)
        }
        updateScroller()
    }

    func attach(_ scroller: LinkedScroller) {
        self.scroller = scroller
        scroller.link = self
        scroller.target = self
        scroller.action = #selector(scrollerMoved(_:))
        updateScroller()
    }

    // MARK: The shared scroll bar

    private var previews: [PDFView] {
        [leader, follower].compactMap { $0?.document == nil ? nil : $0 }
    }

    @objc private func scrollerMoved(_ scroller: NSScroller) {
        let positions = previews.compactMap(position(of:))
        let now = positions.map(\.offset).reduce(0, +)
        let page = positions.map(\.visible).reduce(0, +)
        switch scroller.hitPart {
        case .decrementPage: move(by: -page)
        case .incrementPage: move(by: page)
        default:
            let total = positions.map(\.range).reduce(0, +)
            move(by: scroller.doubleValue * total - now)
        }
    }

    /// Moves the previews `delta` page units in all, half each; what one
    /// can't take, because it's at its top or end, the other takes.
    func move(by delta: CGFloat) {
        let views = previews
        var positions = views.compactMap(position(of:))
        guard positions.count == views.count, !positions.isEmpty else {
            return
        }
        var left = delta
        for pass in 0..<2 {
            for index in positions.indices {
                let share =
                    pass == 0 ? delta / CGFloat(positions.count) : left
                let wanted = positions[index].offset + share
                let moved = min(max(wanted, 0), positions[index].range)
                left -= moved - positions[index].offset
                positions[index].offset = moved
            }
            if abs(left) < 0.5 { break }
        }
        isMatching = true
        for (view, position) in zip(views, positions) {
            scroll(view, to: position.offset)
        }
        isMatching = false
        updateScroller()
    }

    /// The mouse wheel over the shared scroll bar: each preview moves as far
    /// as the wheel asks, on screen.
    func wheel(by screenDelta: CGFloat) {
        let scale = max(leader?.scaleFactor ?? 1, 0.1)
        move(by: 2 * screenDelta / scale)
    }

    private func updateScroller() {
        guard let scroller else { return }
        let positions = previews.compactMap(position(of:))
        let total = positions.map(\.range).reduce(0, +)
        let visible = positions.map(\.visible).reduce(0, +)
        scroller.isEnabled = total > 0.5
        scroller.knobProportion =
            total > 0 ? visible / (visible + total) : 1
        scroller.doubleValue =
            total > 0 ? positions.map(\.offset).reduce(0, +) / total : 0
    }

    // MARK: Positions

    private func position(of view: PDFView) -> Position? {
        guard let documentView = view.documentView,
            let clip = documentView.enclosingScrollView?.contentView
        else { return nil }
        let pages = documentView.bounds
        let range = max(0, pages.height - clip.bounds.height)
        let offset =
            documentView.isFlipped
            ? clip.bounds.minY - pages.minY
            : pages.maxY - clip.bounds.maxY
        return Position(
            offset: min(max(offset, 0), range), range: range,
            visible: clip.bounds.height)
    }

    private func scroll(_ view: PDFView, to offset: CGFloat) {
        guard let documentView = view.documentView,
            let scrollView = documentView.enclosingScrollView
        else { return }
        let clip = scrollView.contentView
        let pages = documentView.bounds
        var origin = clip.bounds.origin
        origin.y =
            documentView.isFlipped
            ? pages.minY + offset
            : pages.maxY - offset - clip.bounds.height
        let wanted = NSRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Watching the previews

    /// Tried again as the preview is laid out and zoomed, until PDFKit has
    /// gone to the page.
    private func startIfReady(_ view: PDFView) {
        guard let page = pendingStart[ObjectIdentifier(view)],
            let clip = view.documentView?.enclosingScrollView?.contentView,
            clip.bounds.height > 0
        else { return }
        view.go(to: page)
        if view.currentPage == page {
            pendingStart[ObjectIdentifier(view)] = nil
        }
    }

    private func observe(_ view: PDFView) {
        for observer in observers[ObjectIdentifier(view)] ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        let center = NotificationCenter.default
        var added: [NSObjectProtocol] = []
        func watch(_ name: Notification.Name, of object: NSView?) {
            guard let object else { return }
            added.append(
                center.addObserver(
                    forName: name, object: object, queue: nil
                ) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.isMatching else { return }
                        if let view { self.startIfReady(view) }
                        self.updateScroller()
                    }
                })
        }
        // A new document can come with a new scroll view, so this is redone
        // each time.
        let clip = view.documentView?.enclosingScrollView?.contentView
        clip?.postsBoundsChangedNotifications = true
        view.documentView?.postsFrameChangedNotifications = true
        watch(NSView.boundsDidChangeNotification, of: clip)
        watch(NSView.frameDidChangeNotification, of: view.documentView)
        added.append(
            center.addObserver(
                forName: .PDFViewScaleChanged, object: view, queue: nil
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    if let self, let view { self.zoomed(view) }
                }
            })
        observers[ObjectIdentifier(view)] = added
    }

    /// The leader zooms when its width changes (it fits the pages); either
    /// zooms when pinched. Before a preview is laid out, PDFKit fits it at a
    /// tiny zoom, which mustn't be passed on.
    private func zoomed(_ view: PDFView) {
        guard !isMatching, view.bounds.width > 1, view.bounds.height > 1
        else { return }
        if let other = [leader, follower].compactMap({ $0 }).first(where: {
            $0 !== view && $0.document != nil
        }) {
            setZoom(of: other, to: view.scaleFactor)
        }
        updateScroller()
    }

    /// Positions are in page units, so keeping one keeps the same place at the
    /// top whatever the zoom.
    private func setZoom(of view: PDFView, to scale: CGFloat) {
        let isStarting = pendingStart[ObjectIdentifier(view)] != nil
        let kept = isStarting ? nil : position(of: view)?.offset
        isMatching = true
        view.autoScales = false
        view.scaleFactor = scale
        view.layoutDocumentView()
        if let kept { scroll(view, to: kept) }
        isMatching = false
        startIfReady(view)
    }

    private func matchZoom() {
        guard let leader, let follower, leader.document != nil,
            follower.document != nil, leader.bounds.width > 1,
            leader.bounds.height > 1,
            abs(follower.scaleFactor - leader.scaleFactor) > 0.0001
        else { return }
        setZoom(of: follower, to: leader.scaleFactor)
    }
}

/// The scroll bar shared by the two previews: always shown, with a track. The
/// mouse wheel over it scrolls both.
final class LinkedScroller: NSScroller {
    weak var link: PreviewScrollLink?

    static var width: CGFloat {
        scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollerStyle = .legacy
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func scrollWheel(with event: NSEvent) {
        let lines: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        link?.wheel(by: -event.scrollingDeltaY * lines)
    }
}

struct LinkedScrollBar: NSViewRepresentable {
    let link: PreviewScrollLink

    func makeNSView(context: Context) -> LinkedScroller {
        let scroller = LinkedScroller(
            frame: CGRect(x: 0, y: 0, width: LinkedScroller.width, height: 100)
        )
        link.attach(scroller)
        return scroller
    }

    func updateNSView(_ scroller: LinkedScroller, context: Context) {}
}
