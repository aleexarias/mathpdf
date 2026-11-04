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
    public static func marks(for annotation: Annotation) -> [(
        mark: PDFAnnotation, color: NSColor
    )] {
        let color = annotation.color.nsColor
        switch annotation.kind {
        case .underline:
            return [(markup(.underline, [annotation.bounds], color), color)]
        case .highlight:
            return [(markup(.highlight, [annotation.bounds], color), color)]
        case let .note(text, anchors):
            let underline = anchorColor(for: color)
            return anchors.map {
                (markup(.underline, [$0], underline), underline)
            } + [
                (noteIcon(annotation, text: text, color: color), color)
            ]
        case let .latex(source, fontSize):
            return [
                (
                    LaTeXAnnotation(
                        bounds: annotation.bounds, source: source,
                        fontSize: fontSize, color: color), color
                )
            ]
        case let .textBox(text, fontSize):
            return [
                (
                    textBox(
                        annotation, text: text, fontSize: fontSize,
                        color: color), .clear
                )
            ]
        }
    }

    /// A highlight or underline over one or more lines, as one annotation (one
    /// quadrilateral per line), the way PDF editors make a multi-line
    /// highlight.
    public static func markup(
        _ type: PDFAnnotationSubtype, _ lines: [CGRect], _ color: NSColor
    ) -> PDFAnnotation {
        let bounds = lines.reduce(CGRect.null) { $0.union($1) }
        let mark = PDFAnnotation(
            bounds: bounds, forType: type, withProperties: nil)
        mark.color = color
        // Relative to the bounds' origin, so moving the bounds moves the mark.
        mark.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            let r = line.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return [
                NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            ]
            .map { NSValue(point: $0) }
        }
        return mark
    }

    public static func noteIcon(
        _ annotation: Annotation, text: String, color: NSColor
    ) -> PDFAnnotation {
        let icon = PDFAnnotation(
            bounds: annotation.bounds, forType: .text, withProperties: nil)
        icon.color = color
        icon.iconType = .comment
        icon.contents = text
        return icon
    }

    /// A text box: a standard PDF FreeText annotation, so other apps can edit
    /// its text. Its colour is the text's; the box itself is clear (it's
    /// tinted while selected).
    public static func textBox(
        _ annotation: Annotation, text: String, fontSize: Double,
        color: NSColor
    ) -> PDFAnnotation {
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
    public static func anchorColor(for color: NSColor) -> NSColor {
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
