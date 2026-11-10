import AppKit
import MathPDFLaTeX
import PDFKit

/// How a text box looks: Helvetica (one of the fonts every PDF reader has),
/// and the size of the box around its text.
public enum TextBoxStyle {
    public static func font(ofSize size: Double) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    /// Room PDFKit leaves between a text box's edge and its text, on every
    /// side.
    static let inset: CGFloat = 3
    /// How much narrower than the box PDFKit lays the text out.
    static let wrapRoom: CGFloat = 4
    /// Width a box needs beyond its text: the inset on both sides, and a
    /// little slack so PDFKit doesn't wrap a line that only just fits.
    static let horizontalRoom = 2 * inset + 2

    /// See `TextBoxLayout.size`.
    @MainActor
    public static func size(
        of text: String, fontSize: Double, width: CGFloat? = nil,
        maxWidth: CGFloat = .infinity
    ) -> CGSize {
        TextBoxLayout(text, fontSize: fontSize).size(
            width: width, maxWidth: maxWidth)
    }

    /// As PDFKit lays out a FreeText.
    fileprivate static func plainSize(
        of text: String, fontSize: Double, width: CGFloat?, maxWidth: CGFloat
    ) -> CGSize {
        let font = font(ofSize: fontSize)
        let boxWidth =
            width
            ?? min(
                naturalWidth(of: text, font: font) + horizontalRoom, maxWidth)
        let lines = lineCount(of: text, font: font, width: boxWidth - wrapRoom)
        // PDFKit spaces a FreeText's lines by the font's height plus a point,
        // tighter than AppKit's usual line height.
        let lineSpacing = font.ascender - font.descender + 1
        return CGSize(
            width: boxWidth,
            height: ceil(CGFloat(lines) * lineSpacing) + 2 * inset)
    }

    private static func naturalWidth(of text: String, font: NSFont) -> CGFloat
    {
        let widths = text.components(separatedBy: .newlines).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        return ceil(widths.max() ?? 0)
    }

    private static func lineCount(
        of text: String, font: NSFont, width: CGFloat
    ) -> Int {
        let storage = NSTextStorage(
            string: text.isEmpty ? " " : text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(
                width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines = 0
        layout.enumerateLineFragments(
            forGlyphRange: layout.glyphRange(for: container)
        ) { _, _, _, _, _ in lines += 1 }
        // a final line break starts an empty line
        if text.last?.isNewline == true { lines += 1 }
        return max(lines, 1)
    }
}

/// A text box's text, measured once and then sized at any width. `text` is as
/// it's drawn, with the user's commands expanded in its formulas.
@MainActor
public struct TextBoxLayout {
    private let text: String
    private let fontSize: Double
    private let math: MathText?

    public init(_ text: String, fontSize: Double) {
        self.text = text
        self.fontSize = fontSize
        math =
            InlineMath.containsMath(text)
            ? MathText(text, fontSize: fontSize, color: .black) : nil
    }

    /// The narrowest the box can be made: a couple of characters, or its
    /// widest formula.
    public var minimumWidth: CGFloat {
        max(2 * CGFloat(fontSize), math?.widestFormula ?? 0)
            + TextBoxStyle.horizontalRoom
    }

    /// Given a `width`, the text wraps to it and only the height follows the
    /// text. Without one, the box is as wide as the longest line, up to
    /// `maxWidth`, wrapping beyond that.
    public func size(width: CGFloat? = nil, maxWidth: CGFloat = .infinity)
        -> CGSize
    {
        math?.boxSize(width: width, maxWidth: maxWidth)
            ?? TextBoxStyle.plainSize(
                of: text, fontSize: fontSize, width: width, maxWidth: maxWidth)
    }
}
