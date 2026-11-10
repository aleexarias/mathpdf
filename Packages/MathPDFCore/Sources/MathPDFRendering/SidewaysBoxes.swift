import MathPDFCore
import MathPDFLaTeX
import PDFKit

/// Formulas and text boxes saved before rotated pages were handled were
/// measured as if the page weren't turned, so on a sideways page their width
/// and height are the wrong way round. Which way a box was measured can be
/// told from what's in it.
@MainActor
public enum SidewaysBoxes {
    /// `annotations` with those boxes the right way round, each around the
    /// same centre.
    public static func corrected(
        _ annotations: [Annotation], in document: PDFDocument
    ) -> [Annotation] {
        annotations.map { annotation in
            guard
                let page = document.page(at: annotation.pageIndex),
                page.rotation % 180 != 0,
                isWrongWayRound(annotation)
            else { return annotation }
            var corrected = annotation
            let old = annotation.bounds
            corrected.bounds = CGRect(
                x: old.midX - old.height / 2, y: old.midY - old.width / 2,
                width: old.height, height: old.width)
            return corrected
        }
    }

    private static func isWrongWayRound(_ annotation: Annotation) -> Bool {
        let bounds = annotation.bounds
        switch annotation.kind {
        case let .latex(source, fontSize, expanded):
            let size = LaTeXRenderer.size(
                of: expanded ?? source, fontSize: fontSize)
            return abs(bounds.width - size.width)
                + abs(bounds.height - size.height)
                < abs(bounds.width - size.height)
                + abs(bounds.height - size.width)
        case let .textBox(text, fontSize, expanded):
            let layout = TextBoxLayout(expanded ?? text, fontSize: fontSize)
            let asSaved = layout.size(width: bounds.width)
            let turned = layout.size(width: bounds.height)
            return abs(asSaved.height - bounds.height)
                < abs(turned.height - bounds.width)
        case .highlight, .underline, .note:
            return false
        }
    }
}
