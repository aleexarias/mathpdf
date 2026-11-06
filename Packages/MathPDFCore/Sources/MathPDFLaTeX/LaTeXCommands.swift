import Foundation

/// The user's own commands, read from definitions written as in a preamble.
/// A formula is expanded once, when it's entered, and stores the result, so
/// nothing that draws a formula needs to know about them.
public struct LaTeXCommands: Equatable, Sendable {
    struct Command: Equatable, Sendable {
        let name: String
        let argumentCount: Int
        /// What the first argument is when left out, which makes it optional.
        let defaultArgument: String?
        let body: String
        let line: Int
    }

    public struct Issue: Hashable, Sendable {
        public let line: Int
        public let message: String
    }

    private(set) var commands: [String: Command] = [:]
    /// What couldn't be read. It stays in the text and defines nothing, and
    /// the rest still works.
    public private(set) var issues: [Issue] = []

    private static let maximumDepth = 64
    private static let maximumExpansion = 100_000

    public var count: Int { commands.count }

    public init(definitions: String = "") {
        var reader = LaTeXReader(definitions)
        while true {
            reader.skipSpaces()
            guard let next = reader.next else { return }
            if next == "%" {
                reader.skipLine()
                continue
            }
            let line = reader.line
            var attempt = reader
            do {
                try readDefinition(from: &attempt, line: line)
                reader = attempt
            } catch {
                issues.append(Issue(line: line, message: error.message))
                reader.skipLine()
            }
        }
    }

    // MARK: Reading definitions

    private mutating func readDefinition(
        from reader: inout LaTeXReader, line: Int
    ) throws(LaTeXProblem) {
        guard reader.next == "\\" else {
            throw LaTeXProblem(message: "This isn't a command definition.")
        }
        let keyword = reader.readCommandName()
        switch keyword {
        case "newcommand", "renewcommand", "providecommand":
            _ = reader.readStar()
            let name = try Self.commandName(
                reader.readArgument(of: keyword), defining: keyword)
            let count = try Self.argumentCount(
                reader.readOptionalArgument(), of: name)
            let defaultArgument = try reader.readOptionalArgument()
            guard defaultArgument == nil || count > 0 else {
                throw LaTeXProblem(
                    message: "\\\(name) has a default but no arguments.")
            }
            guard let body = try reader.readGroup() else {
                throw LaTeXProblem(
                    message: "\\\(name) needs its definition in braces.")
            }
            if keyword == "providecommand", commands[name] != nil { return }
            if keyword == "newcommand", commands[name] != nil {
                issues.append(
                    Issue(
                        line: line,
                        message:
                            "\\\(name) is defined twice: use \\renewcommand."
                    ))
            }
            try add(
                Command(
                    name: name, argumentCount: count,
                    defaultArgument: defaultArgument, body: body, line: line))
        case "DeclareMathOperator":
            let star = reader.readStar() ? "*" : ""
            let name = try Self.commandName(
                reader.readArgument(of: keyword), defining: keyword)
            let operatorName = try reader.readArgument(of: keyword)
            try add(
                Command(
                    name: name, argumentCount: 0, defaultArgument: nil,
                    body: "\\operatorname\(star){\(operatorName)}", line: line
                ))
        case "def":
            reader.skipSpaces()
            let name = try Self.commandName(
                reader.readArgument(of: keyword), defining: keyword)
            var count = 0
            while reader.next == "#" {
                reader.skipCharacter()
                reader.skipCharacter()
                count += 1
            }
            guard let body = try reader.readGroup() else {
                throw LaTeXProblem(
                    message: "\\\(name) needs its definition in braces.")
            }
            try add(
                Command(
                    name: name, argumentCount: count, defaultArgument: nil,
                    body: body, line: line))
        default:
            throw LaTeXProblem(
                message: "\\\(keyword) isn't a command definition.")
        }
    }

    private static func commandName(
        _ argument: String, defining keyword: String
    )
        throws(LaTeXProblem) -> String
    {
        let written = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = written.dropFirst()
        guard written.first == "\\", !name.isEmpty,
            name.allSatisfy(\.isASCIILetter)
        else {
            throw LaTeXProblem(
                message: "\\\(keyword) needs a command name, like \\R.")
        }
        guard name != "begin", name != "end" else {
            throw LaTeXProblem(message: "\(written) can't be redefined.")
        }
        return String(name)
    }

    private static func argumentCount(_ written: String?, of name: String)
        throws(LaTeXProblem) -> Int
    {
        guard let written else { return 0 }
        guard let count = Int(written.trimmingCharacters(in: .whitespaces)),
            (0...9).contains(count)
        else {
            throw LaTeXProblem(
                message: "\\\(name) can have from 0 to 9 arguments.")
        }
        return count
    }

    private mutating func add(_ command: Command) throws(LaTeXProblem) {
        var reader = LaTeXReader(command.body)
        while !reader.isAtEnd {
            guard reader.next == "#" else {
                if reader.next == "\\" {
                    _ = reader.readCommandName()
                } else {
                    reader.skipCharacter()
                }
                continue
            }
            reader.skipCharacter()
            if let number = reader.next?.wholeNumberValue,
                number > command.argumentCount
            {
                let arguments =
                    command.argumentCount == 1
                    ? "1 argument" : "\(command.argumentCount) arguments"
                let uses = "\\\(command.name) uses #\(number)"
                throw LaTeXProblem(message: "\(uses) but has \(arguments).")
            }
            reader.skipCharacter()
        }
        commands[command.name] = command
    }

    // MARK: Expanding

    /// `source` with these commands replaced by their definitions. Commands
    /// that aren't here are left for typesetting, which says if it doesn't
    /// know them.
    public func expansion(of source: String) throws(LaTeXProblem) -> String {
        guard !commands.isEmpty else { return source }
        var budget = Self.maximumExpansion
        return try expansion(of: source, depth: 0, budget: &budget)
    }

    /// `budget` stops definitions that double, themselves or an argument, at
    /// each step, which would run out of memory long before they went deep.
    private func expansion(
        of source: String, depth: Int, budget: inout Int
    ) throws(LaTeXProblem) -> String {
        var reader = LaTeXReader(source)
        var out = TokenText()
        out.append(reader.readText())
        while !reader.isAtEnd {
            let name = reader.readCommandName()
            if let command = commands[name] {
                let filled = try command.filled(from: &reader)
                budget -= filled.count + 1
                guard depth < Self.maximumDepth, budget > 0 else {
                    throw LaTeXProblem(
                        message:
                            "\\\(name) keeps expanding: does it use itself?")
                }
                out.append(
                    try expansion(
                        of: filled, depth: depth + 1, budget: &budget))
            } else if LaTeXReader.textCommands.contains(name),
                let text = try reader.readGroup()
            {
                out.append("\\\(name){\(text)}")
            } else {
                out.append("\\" + name)
            }
            out.append(reader.readText())
        }
        return out.text
    }
}

extension LaTeXCommands.Command {
    /// The definition with the arguments that follow in `reader` put in.
    fileprivate func filled(from reader: inout LaTeXReader)
        throws(LaTeXProblem) -> String
    {
        var arguments: [String] = []
        for index in 0..<argumentCount {
            if index == 0, let defaultArgument {
                arguments.append(
                    try reader.readOptionalArgument() ?? defaultArgument)
            } else {
                arguments.append(try reader.readArgument(of: name))
            }
        }
        guard !arguments.isEmpty else { return body }

        let characters = Array(body)
        var out = TokenText()
        var literal = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let following =
                index + 1 < characters.count ? characters[index + 1] : nil
            if character == "\\", let following {
                literal.append(character)
                literal.append(following)
                index += 2
            } else if character == "#", following == "#" {
                literal.append("#")
                index += 2
            } else if character == "#",
                let number = following?.wholeNumberValue,
                arguments.indices.contains(number - 1)
            {
                out.append(literal)
                literal = ""
                out.append(arguments[number - 1])
                index += 2
            } else {
                literal.append(character)
                index += 1
            }
        }
        out.append(literal)
        return out.text
    }
}

/// Text put together from pieces. TeX reads `\alpha` as one token, but as
/// text, `\alpha` followed by `x` would read as `\alphax`, so a space goes
/// between them.
private struct TokenText {
    private(set) var text = ""

    mutating func append(_ piece: String) {
        if piece.first?.isASCIILetter == true, endsInCommandName {
            text.append(" ")
        }
        text += piece
    }

    private var endsInCommandName: Bool {
        let reversed = text.reversed()
        let letters = reversed.prefix(while: \.isASCIILetter).count
        guard letters > 0 else { return false }
        // an even number of backslashes is `\\` and then a plain word
        let backslashes = reversed.dropFirst(letters).prefix { $0 == "\\" }
        return backslashes.count % 2 == 1
    }
}

extension LaTeXCommands {
    /// Each command tried out with placeholder arguments, so one that can't be
    /// typeset is flagged when it's defined rather than when it's used.
    @MainActor public func typesetIssues() -> [Issue] {
        commands.values.compactMap(typesetIssue(of:))
    }

    @MainActor private func typesetIssue(of command: Command) -> Issue? {
        let required =
            command.argumentCount - (command.defaultArgument == nil ? 0 : 1)
        let sample =
            "\\" + command.name + String(repeating: "{x}", count: required)
        do {
            let result = LaTeXRenderer.typeset(
                try expansion(of: sample), fontSize: 16, color: .black)
            guard case .invalid(let message) = result else { return nil }
            return Issue(
                line: command.line, message: "\\\(command.name): \(message)")
        } catch {
            return Issue(line: command.line, message: error.message)
        }
    }
}
