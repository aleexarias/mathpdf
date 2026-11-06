import AppKit
import MathPDFCore
import MathPDFLaTeX
import MathPDFRendering
import PDFKit

/// Keeps the PDFKit annotations on the pages in line with the session's
/// records, and shows which item is selected. One per window.
@MainActor
final class AnnotationRenderer {
    /// Called with the pages whose annotations were redrawn, so their
    /// thumbnails can refresh.
    var onPagesRedrawn: (([Int]) -> Void)?

    private let session: DocumentSession
    private let pdfView: AnnotationPDFView
    /// What's on the pages for each annotation, and the record it was drawn
    /// from.
    private var rendered: [UUID: Rendered] = [:]
    /// The underline item whose text is shown selected, and whether that text
    /// selection is still ours (rather than one the user made since).
    private var underlineTextShown: UUID?
    private var textSelectionIsOurs = false
    private var isSettingTextSelection = false

    /// What's on the pages for one annotation: its marks and the colour each
    /// is normally drawn in.
    private struct Rendered {
        let annotation: Annotation
        let marks: [(mark: PDFAnnotation, color: NSColor)]
        var isShownSelected = false
    }

    init(session: DocumentSession, pdfView: AnnotationPDFView) {
        self.session = session
        self.pdfView = pdfView
        session.onChange = { [weak self] in self?.render() }
        render()
    }

    func marks(ofItem itemID: UUID) -> [PDFAnnotation] {
        session.annotations.item(itemID).flatMap {
            rendered[$0.id]?.marks.map(\.mark) ?? []
        }
    }

    /// A text selection the user makes replaces the one shown for a selected
    /// underline.
    func textSelectionChanged() {
        if !isSettingTextSelection { textSelectionIsOurs = false }
    }

    /// The PDF view shows a new document: what was drawn went with the old
    /// one.
    func documentReplaced() {
        rendered.removeAll()
        underlineTextShown = nil
        textSelectionIsOurs = false
    }

    // MARK: Drawing

    /// After a locked PDF is unlocked: nothing could be drawn on it before.
    func redraw() {
        render()
    }

    private func render() {
        // PDFKit refuses these, so nothing would be drawn and `rendered` would
        // say it was
        guard let document = pdfView.document, !document.isLocked,
            document.allowsCommenting
        else { return }
        var current: [UUID: Annotation] = [:]
        for annotation in session.annotations {
            current[annotation.id] = annotation
        }

        var changedPages: [PDFPage] = []
        func touched(_ page: PDFPage?) {
            if let page, !changedPages.contains(page) {
                changedPages.append(page)
            }
        }
        for (id, entry) in rendered where current[id] != entry.annotation {
            for (mark, _) in entry.marks {
                touched(mark.page)
                mark.page?.removeAnnotation(mark)
            }
            rendered[id] = nil
        }
        for annotation in session.annotations
        where rendered[annotation.id] == nil {
            guard let page = document.page(at: annotation.pageIndex) else {
                continue
            }
            let marks = AnnotationMarks.marks(
                for: annotation, pageRotation: page.rotation)
            for (mark, _) in marks { page.addAnnotation(mark) }
            rendered[annotation.id] = Rendered(
                annotation: annotation, marks: marks)
            touched(page)
        }
        if !changedPages.isEmpty { pdfView.removeLayersOfRemovedAnnotations() }
        showSelection()
        if !changedPages.isEmpty {
            onPagesRedrawn?(changedPages.map(document.index(for:)))
        }
    }

    // MARK: Selection

    /// The selected item is drawn in a more vivid version of its colours (a
    /// formula or text box gets a tint behind it); nothing else changes.
    private func showSelection() {
        var changedPages: [PDFPage] = []
        for (id, entry) in rendered {
            let selected = entry.annotation.itemID == session.selection
            guard selected != entry.isShownSelected else { continue }
            for (mark, color) in entry.marks {
                if let formula = mark as? LaTeXAnnotation {
                    formula.isSelected = selected
                } else if case .textBox = entry.annotation.kind {
                    // the box's background, not the text
                    mark.color = selected ? Self.selectionTint : color
                } else {
                    mark.color = selected ? Self.vivid(color) : color
                }
                if let page = mark.page, !changedPages.contains(page) {
                    changedPages.append(page)
                }
            }
            rendered[id]?.isShownSelected = selected
        }
        for page in changedPages { pdfView.annotationsChanged(on: page) }
        showUnderlinedText()
    }

    /// Behind a selected text box: the same tint as behind a selected formula.
    private static let selectionTint = NSColor.controlAccentColor
        .withAlphaComponent(0.15)

    /// Halfway to the fully saturated hue, and a touch deeper. Transparency is
    /// kept.
    private static func vivid(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let saturation = rgb.saturationComponent
        return NSColor(
            hue: rgb.hueComponent,
            saturation: saturation + (1 - saturation) * 0.5,
            brightness: rgb.brightnessComponent * 0.95,
            alpha: rgb.alphaComponent)
    }

    /// A selected underline is a thin line, hard to see change colour, so its
    /// text is shown selected too.
    private func showUnderlinedText() {
        let selected = session.selectedAnnotations
        let underlineItem =
            !selected.isEmpty && selected.allSatisfy { $0.kind == .underline }
            ? session.selection : nil
        guard underlineItem != underlineTextShown else { return }
        if underlineTextShown != nil, textSelectionIsOurs {
            setTextSelection(nil)
        }
        underlineTextShown = underlineItem
        guard underlineItem != nil, let document = pdfView.document else {
            return
        }
        let text = PDFSelection(document: document)
        for underline in selected {
            guard let page = document.page(at: underline.pageIndex),
                let line = page.selection(
                    for: pdfView.pageFrame(of: page).middleOfLine(
                        underline.bounds)
                )
            else { continue }
            text.add(line)
        }
        setTextSelection(text)
    }

    private func setTextSelection(_ selection: PDFSelection?) {
        isSettingTextSelection = true
        if let selection {
            pdfView.setCurrentSelection(selection, animate: false)
        } else {
            pdfView.clearSelection()
        }
        isSettingTextSelection = false
        textSelectionIsOurs = selection != nil
    }
}
