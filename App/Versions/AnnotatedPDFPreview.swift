import MathPDFCore
import MathPDFRendering
import PDFKit
import SwiftUI

/// The PDF with one version's annotations drawn on it, to look at and not to
/// edit.
struct AnnotatedPDFPreview: NSViewRepresentable {
    let data: Data
    /// The hash of `data`: a cheaper way than its bytes to tell PDFs apart.
    let documentHash: String
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
        return view
    }

    /// Each version gets a fresh copy of the document: the pages are drawn
    /// anew, so nothing of the version shown before stays on screen.
    func updateNSView(_ view: PreviewPDFView, context: Context) {
        let shown = Coordinator.Shown(
            documentHash: documentHash, annotations: annotations)
        guard context.coordinator.shown != shown,
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
        context.coordinator.shown = shown
        link.show(document, in: view, role: role, startPage: startPage)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        struct Shown: Equatable {
            let documentHash: String
            let annotations: [Annotation]
        }

        var shown: Shown?
    }
}

/// A preview without scroll bars of its own: the shared one moves it (see
/// `PreviewScrollLink`), and it still scrolls with the mouse over it.
final class PreviewPDFView: PDFView {
    /// PDFKit turns scroll bars back on as it likes, so they're swapped for
    /// ones that take no room and draw nothing. Redone for each document,
    /// which can come with a new scroll view.
    func hideScrollBars() {
        guard let scrollView = documentView?.enclosingScrollView else {
            return
        }
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
