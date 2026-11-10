import AppKit
import MathPDFLaTeX

/// A text box with formulas in its text. Other apps see it as an image; the
/// text as typed is kept as its contents. It wraps to its bounds as they
/// change, as a FreeText does.
final class MathTextAnnotation: UprightAnnotation {
    private let text: MathText

    @MainActor
    init(
        bounds: CGRect, text: String, expanded: String?, fontSize: Double,
        color: NSColor, pageRotation: Int
    ) {
        self.text = MathText(
            expanded ?? text, fontSize: fontSize, color: color)
        super.init(
            bounds: bounds, minimumShownSize: .zero, pageRotation: pageRotation
        )
        contents = text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawContent(size: CGSize, in context: CGContext) {
        text.draw(in: context, size: size)
    }
}
