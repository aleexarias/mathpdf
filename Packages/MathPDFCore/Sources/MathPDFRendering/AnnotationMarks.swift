import AppKit
import MathPDFCore
import MathPDFLaTeX
import PDFKit

/// The PDFKit annotations that show mathpdf's annotations: on screen, in the
/// version browser, and in an exported PDF.
@MainActor
public enum AnnotationMarks {
    /// What's drawn for one annotation, and the colour each mark is normally
    /// drawn in.
    public static func marks(
        for annotation: Annotation, pageRotation: Int = 0
    ) -> [(mark: PDFAnnotation, color: NSColor)] {
        let color = annotation.color.nsColor
        func line(
            _ type: PDFAnnotationSubtype, _ rect: CGRect, _ color: NSColor
        ) -> (mark: PDFAnnotation, color: NSColor) {
            (markup(type, [rect], color, pageRotation: pageRotation), color)
        }
        switch annotation.kind {
        case .underline:
            return [line(.underline, annotation.bounds, color)]
        case .highlight:
            return [line(.highlight, annotation.bounds, color)]
        case let .note(text, anchors):
            let underline = anchorColor(for: color)
            return anchors.map { line(.underline, $0, underline) }
                + [(noteIcon(annotation, text: text, color: color), color)]
        case let .latex(source, fontSize, expanded):
            let formula = LaTeXAnnotation(
                bounds: annotation.bounds, source: source, expanded: expanded,
                fontSize: fontSize, color: color, pageRotation: pageRotation)
            return [(formula, color)]
        case let .textBox(text, fontSize, expanded):
            let box = textBox(
                annotation, text: text, fontSize: fontSize, expanded: expanded,
                color: color, pageRotation: pageRotation)
            return [(box, .clear)]
        }
    }

    /// A highlight or underline over one or more lines, as one annotation with
    /// a quadrilateral per line. The corners go in the order they have on
    /// screen, which is what puts an underline under the text on a rotated
    /// page.
    static func markup(
        _ type: PDFAnnotationSubtype, _ lines: [CGRect], _ color: NSColor,
        pageRotation: Int = 0
    ) -> PDFAnnotation {
        let frame = PageFrame(box: .zero, rotation: pageRotation)
        let bounds = lines.reduce(CGRect.null) { $0.union($1) }
        let mark = PDFAnnotation(
            bounds: bounds, forType: type, withProperties: nil)
        mark.color = color
        // Relative to the bounds' origin, so moving the bounds moves the mark.
        mark.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            let corners = frame.shownCorners(
                of: line.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
            return [
                corners.topLeft, corners.topRight, corners.bottomLeft,
                corners.bottomRight,
            ]
            .map { NSValue(point: $0) }
        }
        return mark
    }

    static func noteIcon(
        _ annotation: Annotation, text: String, color: NSColor
    ) -> PDFAnnotation {
        let icon = PDFAnnotation(
            bounds: annotation.bounds, forType: .text, withProperties: nil)
        icon.color = color
        icon.iconType = .comment
        icon.contents = text
        return icon
    }

    /// A text box. Plain text is a standard PDF FreeText annotation, so other
    /// apps can edit it: its colour is the text's, and the box itself is clear
    /// (it's tinted while selected). Text with formulas is drawn by mathpdf.
    static func textBox(
        _ annotation: Annotation, text: String, fontSize: Double,
        expanded: String?, color: NSColor, pageRotation: Int
    ) -> PDFAnnotation {
        if InlineMath.containsMath(expanded ?? text) {
            return MathTextAnnotation(
                bounds: annotation.bounds, text: text, expanded: expanded,
                fontSize: fontSize, color: color, pageRotation: pageRotation)
        }
        let box = PDFAnnotation(
            bounds: annotation.bounds, forType: .freeText, withProperties: nil)
        box.contents = text
        box.font = TextBoxStyle.font(ofSize: fontSize)
        box.fontColor = color
        box.color = .clear
        box.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        box.border = border
        return box
    }

    /// The subtle underline under a note's text: the note's colour, a little
    /// deeper, since a pale note colour would be nearly invisible as a thin
    /// line.
    static func anchorColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            hue: rgb.hueComponent,
            saturation: max(rgb.saturationComponent, 0.6),
            brightness: min(rgb.brightnessComponent, 0.88), alpha: 1)
    }
}

extension RGBAColor {
    public var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
