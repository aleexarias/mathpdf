import AppKit
import CoreText
import MathPDFLaTeX

/// A text box's text with its formulas typeset, ready to be laid out in lines
/// at any width. Words and formulas wrap together, and a formula is never
/// split; each line is as tall as what's on it. Typesetting needs the main
/// thread, but laying out and drawing don't, so an exported PDF can be drawn
/// off it.
struct MathText {
    private struct TextRun {
        let string: String
        let font: NSFont
        let color: NSColor
        let line: CTLine
        let width: CGFloat

        init(_ string: String, font: NSFont, color: NSColor) {
            self.string = string
            self.font = font
            self.color = color
            line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: string,
                    attributes: [.font: font, .foregroundColor: color]))
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        func with(_ string: Substring) -> TextRun {
            TextRun(String(string), font: font, color: color)
        }
    }

    /// Something on a line: text, or a formula.
    private enum Run {
        case text(TextRun)
        case formula(LaTeXRenderer.Typeset)

        var width: CGFloat {
            switch self {
            case .text(let text): text.width
            case .formula(let typeset): typeset.size.width
            }
        }

        var ascent: CGFloat {
            switch self {
            case .text(let text): text.font.ascender
            case .formula(let typeset): typeset.size.height - typeset.baseline
            }
        }

        var descent: CGFloat {
            switch self {
            case .text(let text): -text.font.descender
            case .formula(let typeset): typeset.baseline
            }
        }
    }

    private enum Token {
        /// Runs with no space between them, kept on one line when they fit.
        case word([Run])
        case space(width: CGFloat)
        case lineBreak
    }

    private struct Line {
        var runs: [(run: Run, x: CGFloat)] = []
        var width: CGFloat = 0
        var ascent: CGFloat
        var descent: CGFloat

        /// Spaced as PDFKit spaces a FreeText's lines.
        var height: CGFloat { ascent + descent + 1 }

        mutating func place(_ run: Run, after space: CGFloat = 0) {
            runs.append((run, width + space))
            width += space + run.width
            ascent = max(ascent, run.ascent)
            descent = max(descent, run.descent)
        }
    }

    private let tokens: [Token]
    private let font: NSFont

    /// `text` as it's drawn: with the user's commands expanded.
    @MainActor
    init(_ text: String, fontSize: Double, color: NSColor) {
        let font = TextBoxStyle.font(ofSize: fontSize)
        var tokens: [Token] = []
        var word: [Run] = []
        var letters = ""
        var spaces = ""
        func endLetters() {
            if !letters.isEmpty {
                word.append(.text(TextRun(letters, font: font, color: color)))
            }
            letters = ""
        }
        func endWord() {
            endLetters()
            if !word.isEmpty { tokens.append(.word(word)) }
            word = []
        }
        func endSpaces() {
            if !spaces.isEmpty {
                let width = TextRun(spaces, font: font, color: color).width
                tokens.append(.space(width: width))
            }
            spaces = ""
        }
        for piece in InlineMath.pieces(of: text) {
            switch piece {
            case .text(let text):
                for character in text {
                    if character.isNewline {
                        endWord()
                        endSpaces()
                        tokens.append(.lineBreak)
                    } else if character.isWhitespace {
                        endWord()
                        spaces.append(character)
                    } else {
                        endSpaces()
                        letters.append(character)
                    }
                }
            case .math(let source):
                endSpaces()
                endLetters()
                word.append(
                    Self.formulaRun(source, fontSize: fontSize, color: color))
            }
        }
        endWord()
        endSpaces()
        self.tokens = tokens
        self.font = font
    }

    /// The widest formula: no box can be narrower.
    var widestFormula: CGFloat {
        tokens.reduce(0) { widest, token in
            guard case .word(let runs) = token else { return widest }
            return runs.reduce(widest) {
                guard case .formula = $1 else { return $0 }
                return max($0, $1.width)
            }
        }
    }

    /// The box for the text, as `TextBoxLayout.size` gives it.
    func boxSize(width: CGFloat?, maxWidth: CGFloat) -> CGSize {
        let natural = lines(width: .infinity).map(\.width).max() ?? 0
        let boxWidth =
            width ?? min(natural + TextBoxStyle.horizontalRoom, maxWidth)
        let height = lines(width: boxWidth - 2 * TextBoxStyle.inset)
            .reduce(0) { $0 + $1.height }
        return CGSize(
            width: boxWidth, height: ceil(height) + 2 * TextBoxStyle.inset)
    }

    /// Draws the text in a box of `size` with its origin at the context's
    /// origin, bottom left.
    func draw(in context: CGContext, size: CGSize) {
        let inset = TextBoxStyle.inset
        var top = size.height - inset
        for line in lines(width: size.width - 2 * inset) {
            let baseline = top - line.ascent
            for (run, x) in line.runs {
                switch run {
                case .text(let text):
                    context.textPosition = CGPoint(x: inset + x, y: baseline)
                    CTLineDraw(text.line, context)
                case .formula(let typeset):
                    context.saveGState()
                    context.translateBy(
                        x: inset + x, y: baseline - typeset.baseline)
                    typeset.draw(in: context)
                    context.restoreGState()
                }
            }
            top -= line.height
        }
    }

    /// The lines at `width`. Spaces at the start of a wrapped line are
    /// dropped; a word wider than a line is broken between characters.
    private func lines(width: CGFloat) -> [Line] {
        var lines = Lines(
            width: width,
            empty: Line(ascent: font.ascender, descent: -font.descender))
        var space: CGFloat = 0
        var isParagraphStart = true
        for token in tokens {
            switch token {
            case .lineBreak:
                lines.wrap()
                space = 0
                isParagraphStart = true
            case .space(let width):
                if !lines.current.runs.isEmpty || isParagraphStart {
                    space += width
                }
            case .word(let runs):
                lines.place(word: runs, after: space)
                space = 0
                isParagraphStart = false
            }
        }
        return lines.done + [lines.current]
    }

    /// Lines being filled up to `width`.
    private struct Lines {
        let width: CGFloat
        let empty: Line
        var done: [Line] = []
        var current: Line

        init(width: CGFloat, empty: Line) {
            self.width = width
            self.empty = empty
            current = empty
        }

        mutating func wrap() {
            done.append(current)
            current = empty
        }

        /// On this line after `space` if it fits, or else on the next.
        mutating func place(word runs: [Run], after space: CGFloat) {
            let wordWidth = runs.reduce(0) { $0 + $1.width }
            var space = space
            if !current.runs.isEmpty,
                current.width + space + wordWidth > width
            {
                wrap()
                space = 0
            }
            guard current.width + space + wordWidth <= width else {
                for run in runs { placeBroken(run) }
                return
            }
            current.place(runs[0], after: space)
            for run in runs.dropFirst() { current.place(run) }
        }

        /// Part of a word too wide for a line: a formula whole, on a line of
        /// its own if need be, and text split between characters.
        private mutating func placeBroken(_ run: Run) {
            guard case .text(let text) = run else {
                if !current.runs.isEmpty, current.width + run.width > width {
                    wrap()
                }
                current.place(run)
                return
            }
            var rest = Substring(text.string)
            while !rest.isEmpty {
                var fitting = rest.prefix(0)
                for end in rest.indices.dropFirst() + [rest.endIndex] {
                    let candidate = rest[..<end]
                    guard
                        current.width + text.with(candidate).width <= width
                    else { break }
                    fitting = candidate
                }
                if fitting.isEmpty, !current.runs.isEmpty {
                    wrap()
                    continue
                }
                let part = fitting.isEmpty ? rest.prefix(1) : fitting
                current.place(.text(text.with(part)))
                rest = rest[part.endIndex...]
                if !rest.isEmpty { wrap() }
            }
        }
    }

    /// A formula that can't be typeset shows its source in red, so nothing
    /// typed is hidden.
    @MainActor
    private static func formulaRun(
        _ source: String, fontSize: Double, color: NSColor
    ) -> Run {
        if case .formula(let typeset) = LaTeXRenderer.typeset(
            source, fontSize: fontSize, color: color, style: .inline)
        {
            return .formula(typeset)
        }
        // not a label color: the page stays white in dark mode
        return .text(
            TextRun(
                "$\(source)$",
                font: LaTeXRenderer.errorFont(fontSize: fontSize),
                color: .systemRed))
    }
}
