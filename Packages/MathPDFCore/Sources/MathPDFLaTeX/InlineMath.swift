/// Text with LaTeX formulas between `$` signs, as a text box holds it. `\$` is
/// a dollar sign; a `$` with no closing one on its line, or an empty `$$`, is
/// plain text.
public enum InlineMath {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case math(String)
    }

    /// The text and formulas of `text`, in order, with `\$` in the text shown
    /// as `$`.
    public static func pieces(of text: String) -> [Piece] {
        scan(text).map { piece in
            guard case .text(let raw) = piece else { return piece }
            return .text(raw.replacingOccurrences(of: #"\$"#, with: "$"))
        }
    }

    public static func containsMath(_ text: String) -> Bool {
        scan(text).contains { $0.isMath }
    }

    /// `text` with the source of each formula replaced by `transform`'s
    /// result, and everything else as written.
    public static func mappingMath<Failure: Error>(
        _ text: String, _ transform: (String) throws(Failure) -> String
    ) throws(Failure) -> String {
        var result = ""
        for piece in scan(text) {
            switch piece {
            case .text(let raw): result += raw
            case .math(let source): result += "$\(try transform(source))$"
            }
        }
        return result
    }

    /// The pieces as written: text keeps its `\$`.
    private static func scan(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var textStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\\":
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
            case "$":
                let open = text.index(after: index)
                guard let close = closingDollar(in: text, from: open) else {
                    index = open
                    continue
                }
                if close > open {
                    if textStart < index {
                        pieces.append(.text(String(text[textStart..<index])))
                    }
                    pieces.append(.math(String(text[open..<close])))
                    textStart = text.index(after: close)
                }
                index = text.index(after: close)
            default:
                index = text.index(after: index)
            }
        }
        if textStart < text.endIndex {
            pieces.append(.text(String(text[textStart...])))
        }
        return pieces
    }

    /// The next `$` on the same line that isn't escaped.
    private static func closingDollar(
        in text: String, from start: String.Index
    ) -> String.Index? {
        var index = start
        while index < text.endIndex, !text[index].isNewline {
            switch text[index] {
            case "$":
                return index
            case "\\":
                index = text.index(after: index)
                if index < text.endIndex, !text[index].isNewline {
                    index = text.index(after: index)
                }
            default:
                index = text.index(after: index)
            }
        }
        return nil
    }
}

extension InlineMath.Piece {
    var isMath: Bool {
        if case .math = self { return true }
        return false
    }
}
