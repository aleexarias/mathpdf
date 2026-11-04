import MathPDFCore
import MathPDFRendering
import PDFKit
import SwiftUI

/// The PDF with one version's annotations drawn on it, to look at and not to
/// edit.
struct AnnotatedPDFPreview: NSViewRepresentable {
    let data: Data
    let annotations: [Annotation]
    let startPage: Int
    let link: PreviewScrollLink
    let role: PreviewScrollLink.Role

    func makeNSView(context: Context) -> PreviewPDFView {
        let view = PreviewPDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.backgroundColor = Viewer.pageBackground
        view.hidesScrollBars = role == .follower
        return view
    }

    /// Each version gets a fresh copy of the document: the pages are drawn
    /// anew, so nothing of the version shown before stays on screen.
    func updateNSView(_ view: PreviewPDFView, context: Context) {
        guard context.coordinator.shown != annotations,
            let document = PDFDocument(data: data)
        else { return }
        for annotation in annotations {
            guard let page = document.page(at: annotation.pageIndex) else {
                continue
            }
            for (mark, _) in AnnotationMarks.marks(for: annotation) {
                page.addAnnotation(mark)
            }
        }
        context.coordinator.shown = annotations
        link.show(document, in: view, role: role, startPage: startPage)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: [Annotation]?
    }
}

/// A preview that can do without scroll bars.
final class PreviewPDFView: PDFView {
    var hidesScrollBars = false

    /// PDFKit turns scroll bars back on as it likes, so they're swapped for
    /// ones that take no room and draw nothing. Redone for each document,
    /// which can come with a new scroll view.
    func applyScrollBarSetting() {
        guard hidesScrollBars,
            let scrollView = documentView?.enclosingScrollView
        else { return }
        if !(scrollView.verticalScroller is InvisibleScroller) {
            scrollView.verticalScroller = InvisibleScroller()
        }
        if !(scrollView.horizontalScroller is InvisibleScroller) {
            scrollView.horizontalScroller = InvisibleScroller()
        }
    }
}

private final class InvisibleScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat { 0 }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Makes the two previews move as one, with a single scroll bar: scrolling or
/// zooming either shows the same place in the other. Both show the same PDF at
/// the same zoom, so the same scroll position shows the same place. The leader
/// keeps the scroll bar and fits the pages to its width; the follower takes
/// the leader's zoom.
@MainActor
final class PreviewScrollLink {
    enum Role { case leader, follower }

    private weak var leader: PDFView?
    private weak var follower: PDFView?
    /// Set while a preview is being changed or moved to match the other, so
    /// that isn't echoed back.
    private var isMatching = false
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// Shows a version's document. The preview keeps the place the other one
    /// shows (or opens at `startPage` if it's the first): switching versions
    /// doesn't move anything.
    func show(
        _ document: PDFDocument, in view: PDFView, role: Role, startPage: Int
    ) {
        switch role {
        case .leader: leader = view
        case .follower: follower = view
        }
        isMatching = true
        // scrolls to the top, which mustn't move the other preview
        view.document = document
        (view as? PreviewPDFView)?.applyScrollBarSetting()
        view.layoutDocumentView()
        observe(view)
        isMatching = false
        if let other = partner(of: view) {
            matchZoom()
            match(view, to: other)
        } else if let page = document.page(
            at: min(startPage, document.pageCount - 1))
        {
            view.go(to: page)
        }
    }

    // MARK: Following each other

    private func partner(of view: PDFView) -> PDFView? {
        let other = view === leader ? follower : leader
        return other?.document != nil ? other : nil
    }

    private func observe(_ view: PDFView) {
        for observer in observers[ObjectIdentifier(view)] ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        let center = NotificationCenter.default
        var added: [NSObjectProtocol] = []
        // A new document can come with a new scroll view, so this is redone
        // each time.
        if let clip = view.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            added.append(
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clip,
                    queue: nil
                ) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        if let self, let view { self.scrolled(view) }
                    }
                })
        }
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

    private func scrolled(_ view: PDFView) {
        guard !isMatching, let other = partner(of: view) else { return }
        match(other, to: view)
    }

    /// The leader zooms when its width changes (it fits the pages); either
    /// zooms when pinched.
    private func zoomed(_ view: PDFView) {
        guard !isMatching, let other = partner(of: view) else { return }
        isMatching = true
        other.autoScales = false
        other.scaleFactor = view.scaleFactor
        isMatching = false
        match(other, to: view)
    }

    private func matchZoom() {
        guard let leader, let follower, leader.document != nil,
            follower.document != nil,
            abs(follower.scaleFactor - leader.scaleFactor) > 0.0001
        else { return }
        isMatching = true
        follower.autoScales = false
        follower.scaleFactor = leader.scaleFactor
        follower.layoutDocumentView()
        isMatching = false
    }

    /// Scrolls `view` so its top shows what the top of `source` shows.
    private func match(_ view: PDFView, to source: PDFView) {
        guard let from = source.documentView?.enclosingScrollView?.contentView,
            let scrollView = view.documentView?.enclosingScrollView,
            let documentView = view.documentView
        else { return }
        let clip = scrollView.contentView
        var origin = from.bounds.origin
        // The previews can differ a little in height, and unflipped scroll
        // positions are measured from the bottom: line up the tops instead.
        if !documentView.isFlipped {
            origin.y += from.bounds.height - clip.bounds.height
        }
        isMatching = true
        defer { isMatching = false }
        let wanted = NSRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
