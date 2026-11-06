import Foundation

/// What's wrong with some LaTeX, in words for the user.
public struct LaTeXProblem: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Walks LaTeX source one token at a time, the way TeX reads arguments.
struct LaTeXReader {
    /// Commands whose argument is text, left exactly as typed.
    static let textCommands: Set<String> = [
        "text", "textrm", "textbf", "textit", "textsf", "texttt", "mbox",
    ]

    private let text: [Character]
    private var index = 0

    init(_ source: String) {
        text = Array(source)
    }

    var isAtEnd: Bool { index >= text.count }

    var next: Character? { isAtEnd ? nil : text[index] }

    /// The line reached, counted from 1.
    var line: Int {
        text[..<min(index, text.count)].count(where: \.isNewline) + 1
    }

    mutating func skipCharacter() {
        index += 1
    }

    mutating func skipSpaces() {
        while index < text.count, text[index].isWhitespace { index += 1 }
    }

    mutating func skipLine() {
        while index < text.count, !text[index].isNewline { index += 1 }
    }

    mutating func readText() -> String {
        let start = index
        while index < text.count, text[index] != "\\" { index += 1 }
        return String(text[start..<index])
    }

    /// After the backslash: a name of letters, or a single other character
    /// (`\,`, `\{`, `\\`).
    mutating func readCommandName() -> String {
        index += 1
        guard index < text.count else { return "" }
        let start = index
        if text[index].isASCIILetter {
            while index < text.count, text[index].isASCIILetter {
                index += 1
            }
        } else {
            index += 1
        }
        return String(text[start..<index])
    }

    mutating func readStar() -> Bool {
        guard index < text.count, text[index] == "*" else { return false }
        index += 1
        return true
    }

    /// A command's argument: a `{group}`, or else one token, as TeX allows
    /// (`\dfrac12`).
    mutating func readArgument(of command: String) throws(LaTeXProblem)
        -> String
    {
        if let group = try readGroup() { return group }
        guard index < text.count, text[index] != "}" else {
            throw LaTeXProblem(
                message: command.hasPrefix("\\")
                    ? "\(command) needs an argument."
                    : "\\\(command) needs an argument.")
        }
        if text[index] == "\\" {
            let start = index
            _ = readCommandName()
            return String(text[start..<index])
        }
        index += 1
        return String(text[index - 1])
    }

    /// The contents of a `{group}` if one comes next, with nested groups and
    /// escaped braces.
    mutating func readGroup() throws(LaTeXProblem) -> String? {
        skipSpaces()
        guard index < text.count, text[index] == "{" else { return nil }
        return try readBalanced(open: "{", close: "}")
    }

    mutating func readOptionalArgument() throws(LaTeXProblem) -> String? {
        skipSpaces()
        guard index < text.count, text[index] == "[" else { return nil }
        return try readBalanced(open: "[", close: "]")
    }

    private mutating func readBalanced(open: Character, close: Character)
        throws(LaTeXProblem) -> String
    {
        index += 1
        let start = index
        var depth = 0
        while index < text.count {
            switch text[index] {
            // the escaped character can't open or close anything
            case "\\": index += 1
            case "{": depth += 1
            case "}" where depth > 0: depth -= 1
            case close where depth == 0:
                defer { index += 1 }
                return String(text[start..<index])
            default: break
            }
            index += 1
        }
        throw LaTeXProblem(
            message: close == "}" ? "Missing closing brace" : "Missing ]")
    }
}

extension LaTeXReader {
    private static let deepestNesting = 100

    /// SwiftMath is recursive: a formula nested thousands of levels deep
    /// overflows the stack, which takes the app down with no error to catch,
    /// and one a thousand deep can take minutes on the main thread. Counts
    /// what nests without braces too: `\sqrt\sqrt x`, `a \over b \over c`.
    static func isNestedTooDeeply(_ source: String) -> Bool {
        var reader = LaTeXReader(source)
        var groups = 0
        var commandsInARow = 0
        var fractions = 0
        while let character = reader.next {
            if character == "\\" {
                commandsInARow += 1
                switch reader.readCommandName() {
                case "left", "begin": groups += 1
                case "right", "end": groups = max(groups - 1, 0)
                case "over", "atop", "choose", "brace", "brack": fractions += 1
                default: break
                }
            } else {
                reader.skipCharacter()
                if !character.isWhitespace { commandsInARow = 0 }
                switch character {
                case "{", "[": groups += 1
                case "}", "]": groups = max(groups - 1, 0)
                default: break
                }
            }
            if groups + commandsInARow + fractions > deepestNesting {
                return true
            }
        }
        return false
    }
}

extension Character {
    var isASCIILetter: Bool { isASCII && isLetter }
}
