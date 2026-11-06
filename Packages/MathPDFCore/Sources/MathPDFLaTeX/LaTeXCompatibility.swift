import Foundation
import SwiftMath

/// SwiftMath typesets most of the math people write, but not every common
/// command. This fills the easy gaps just before typesetting; the saved source
/// is never changed.
/// - Symbols it lacks are added to its table once (`\iint`, `\implies`,
///   `\nleq`, …).
/// - Commands with a close equivalent are rewritten (`\dfrac` → `\frac`,
///   `\operatorname{tr}` → an operator, `align` → `aligned`, `\color{red}` →
///   hex, …). Anything else is left for SwiftMath, which reports it as not
///   supported.
@MainActor
enum LaTeXCompatibility {
    static func rewrite(_ source: String) throws(LaTeXProblem) -> String {
        _ = symbolsAdded
        var rewriter = Rewriter(source)
        return try rewriter.rewriteAll()
    }

    // MARK: Rewriting

    /// Commands written differently for SwiftMath. `\tfrac` is drawn as big as
    /// `\frac`.
    private static let renamed: [String: String] = [
        "dfrac": #"\frac"#, "tfrac": #"\frac"#, "cfrac": #"\frac"#,
        "boldsymbol": #"\bm"#, "pmb": #"\bm"#, "mathscr": #"\mathcal"#,
        "lVert": #"\|"#, "rVert": #"\|"#, "lvert": "|", "rvert": "|",
        "lt": "<", "gt": ">",
        "dots": #"\ldots"#, "dotsc": #"\ldots"#, "dotso": #"\ldots"#,
        "dotsb": #"\cdots"#, "dotsm": #"\cdots"#,
        "Box": #"\square"#, "qed": #"\square"#,
        "nonumber": "", "notag": "",
        "&": #"\mathpdfampersand "#,
        "bmod": #"\mathpdfbmod "#,
    ]

    /// `\big(` and the like: SwiftMath can't size a lone delimiter, so it's
    /// drawn at its normal size.
    private static let sizeCommands: Set<String> = [
        "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl",
        "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm",
    ]

    /// What `\not` followed by a symbol becomes.
    private static let negations: [String: String] = [
        "=": #"\neq "#, "<": #"\nless "#, ">": #"\ngtr "#,
        "in": #"\notin "#, "ni": #"\notni "#, "equiv": #"\nequiv "#,
        "sim": #"\nsim "#, "simeq": #"\nsimeq "#,
        "approx": #"\napprox "#, "cong": #"\ncong "#, "subset": #"\nsubset "#,
        "supset": #"\nsupset "#,
        "subseteq": #"\nsubseteq "#, "supseteq": #"\nsupseteq "#,
        "le": #"\nleq "#, "leq": #"\nleq "#,
        "ge": #"\ngeq "#, "geq": #"\ngeq "#, "mid": #"\nmid "#,
        "parallel": #"\nparallel "#,
        "exists": #"\nexists "#, "prec": #"\nprec "#, "succ": #"\nsucc "#,
    ]

    /// Environments SwiftMath doesn't have, and the closest one it does (""
    /// drops it). An array's columns are all centred.
    private static let environments: [String: String] = [
        "align": "aligned", "align*": "aligned", "gather*": "gather",
        "array": "matrix",
        "smallmatrix": "matrix", "dcases": "cases", "equation": "",
        "equation*": "",
    ]

    /// The basic colours of LaTeX's xcolor package. SwiftMath only reads hex.
    private static let colors: [String: String] = [
        "black": "#000000", "white": "#FFFFFF", "red": "#FF0000",
        "green": "#00FF00", "blue": "#0000FF",
        "cyan": "#00FFFF", "magenta": "#FF00FF", "yellow": "#FFFF00",
        "gray": "#808080", "grey": "#808080",
        "darkgray": "#404040", "lightgray": "#BFBFBF", "brown": "#BF8040",
        "lime": "#BFFF00",
        "olive": "#808000", "orange": "#FF8000", "pink": "#FFBFBF",
        "purple": "#BF0040",
        "teal": "#008080", "violet": "#800080",
    ]

    /// Copies the source out one token at a time, rewriting what needs it.
    @MainActor
    private struct Rewriter {
        private var reader: LaTeXReader

        init(_ source: String) {
            reader = LaTeXReader(source)
        }

        mutating func rewriteAll() throws(LaTeXProblem) -> String {
            var out = reader.readText()
            while !reader.isAtEnd {
                let name = reader.readCommandName()
                out += try rewrite(command: name)
                out += reader.readText()
            }
            return out
        }

        private mutating func rewrite(command name: String)
            throws(LaTeXProblem)
            -> String
        {
            if let replacement = renamed[name] { return replacement }
            if sizeCommands.contains(name) { return "" }
            switch name {
            case "operatorname":
                let limits = reader.readStar()
                let operatorName = operatorName(
                    try reader.readArgument(of: name))
                // SwiftMath crashes laying out an operator with no name
                guard !operatorName.isEmpty else {
                    throw LaTeXProblem(
                        message: #"\operatorname needs a name."#)
                }
                return operatorCommand(named: operatorName, limits: limits)
            case "overset", "stackrel":
                let above = try reader.readArgument(of: name)
                return try limitsOperator(
                    over: reader.readArgument(of: name), command: name)
                    + "^{\(try LaTeXCompatibility.rewrite(above))}"
            case "underset":
                let below = try reader.readArgument(of: name)
                return try limitsOperator(
                    over: reader.readArgument(of: name), command: name)
                    + "_{\(try LaTeXCompatibility.rewrite(below))}"
            case "xrightarrow", "xleftarrow":
                let below = try reader.readOptionalArgument()
                let above = try reader.readArgument(of: name)
                var out = operatorCommand(
                    named: name == "xrightarrow" ? "\u{2192}" : "\u{2190}",
                    limits: true)
                out += "^{\(try LaTeXCompatibility.rewrite(above))}"
                if let below {
                    out += "_{\(try LaTeXCompatibility.rewrite(below))}"
                }
                return out
            case "pmod":
                return #"\quad(\mathrm{mod}\;"#
                    + (try LaTeXCompatibility.rewrite(
                        reader.readArgument(of: name)))
                    + ")"
            case "mod":
                return #"\quad\mathrm{mod}\;"#
                    + (try LaTeXCompatibility.rewrite(
                        reader.readArgument(of: name)))
            case "substack":  // rows in script size, as under a sum
                let rows = try LaTeXCompatibility.rewrite(
                    reader.readArgument(of: name))
                return #"\begin{matrix}\scriptstyle "#
                    + rows.replacingOccurrences(
                        of: #"\\"#, with: #"\\\scriptstyle "#)
                    + #"\end{matrix}"#
            case "tag":
                let starred = reader.readStar()
                let label = try reader.readArgument(of: name)
                return starred
                    ? #"\qquad\text{\#(label)}"# : #"\qquad\text{(\#(label))}"#
            case "label":
                _ = try reader.readArgument(of: name)
                return ""
            case "color", "textcolor":
                let color = try reader.readArgument(of: name)
                let trimmed = color.trimmingCharacters(in: .whitespaces)
                return "\\\(name){\(colors[trimmed] ?? color)}"
            case "not":
                return try negation()
            case "begin", "end":
                let environment = try reader.readArgument(of: name)
                guard let replacement = environments[environment] else {
                    return "\\\(name){\(environment)}"
                }
                if name == "begin", environment == "array" {
                    _ = try reader.readArgument(of: #"\begin{array}"#)
                }  // column spec
                return replacement.isEmpty ? "" : "\\\(name){\(replacement)}"
            case _ where LaTeXReader.textCommands.contains(name):
                guard let argument = try reader.readGroup() else {
                    return "\\" + name
                }
                return "\\\(name){\(argument)}"
            default:
                return "\\" + name
            }
        }

        /// `\not=`, `\not\in`, …: the negated symbol, if there is one.
        private mutating func negation() throws(LaTeXProblem) -> String {
            reader.skipSpaces()
            guard let next = reader.next else {
                throw LaTeXProblem(message: #"\not needs a symbol after it."#)
            }
            let symbol: String
            if next == "\\" {
                symbol = reader.readCommandName()
            } else {
                symbol = String(next)
                reader.skipCharacter()
            }
            guard let negated = negations[symbol] else {
                let written =
                    symbol.first?.isLetter == true ? "\\" + symbol : symbol
                throw LaTeXProblem(
                    message: #"Command not supported: \not"# + written)
            }
            return negated
        }
    }

    // MARK: Operators

    /// Commands made for operators, by name: `\operatorname{tr}` becomes one
    /// with "tr" as its name, `\overset{a}{=}` one with "=" and its limits
    /// above and below.
    private static var operatorCommands: [String: String] = [:]

    private static func operatorCommand(named name: String, limits: Bool)
        -> String
    {
        let key = (limits ? "limits " : "") + name
        if let command = operatorCommands[key] { return command }
        let symbol = "mathpdfop" + letters(for: operatorCommands.count)
        MTMathAtomFactory.add(
            latexSymbol: symbol,
            value: MTMathAtomFactory.operatorWithName(name, limits: limits))
        let command = "\\\(symbol) "
        operatorCommands[key] = command
        return command
    }

    /// The text of `\operatorname{…}`: letters and spaces as written, with
    /// `\,` as a space.
    private static func operatorName(_ argument: String) -> String {
        argument.replacingOccurrences(of: #"\,"#, with: " ")
            .replacingOccurrences(of: #"\;"#, with: " ")
            .replacingOccurrences(of: #"\ "#, with: " ").replacingOccurrences(
                of: #"\!"#, with: ""
            )
            .trimmingCharacters(in: .whitespaces)
    }

    /// An operator to put limits on, for `\overset` and friends. Only a symbol
    /// or a word can go under them: `=`, `\to`, `\arg\min`.
    private static func limitsOperator(over base: String, command: String)
        throws(LaTeXProblem) -> String
    {
        let simple: Set<MTMathAtomType> = [
            .ordinary, .number, .variable, .largeOperator, .binaryOperator,
            .unaryOperator, .relation, .open, .close, .punctuation,
        ]
        guard
            let atoms = MTMathListBuilder.build(fromString: try rewrite(base))?
                .atoms, !atoms.isEmpty,
            atoms.allSatisfy({
                simple.contains($0.type) && $0.subScript == nil
                    && $0.superScript == nil && !$0.nucleus.isEmpty
            })
        else {
            throw LaTeXProblem(
                message:
                    "\\\(command) only works over a single symbol or word.")
        }
        let name = atoms.map(\.nucleus).joined(
            separator: atoms.count > 1
                && atoms.contains { $0.type == .largeOperator } ? " " : "")
        return operatorCommand(named: name, limits: true)
    }

    /// "a", "b", …, "z", "ba", … (command names can only have letters).
    private static func letters(for number: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var number = number, out = ""
        repeat {
            out = String(alphabet[number % 26]) + out
            number /= 26
        } while number > 0
        return out
    }

    // MARK: Symbols

    private enum Kind {
        case ordinary, relation, binary, integral
    }

    /// Symbols SwiftMath lacks, by name, with the character drawn for each.
    private static let symbols:
        [(name: String, character: String, kind: Kind)] = [
            ("iint", "\u{222C}", .integral), ("iiint", "\u{222D}", .integral),
            ("oiint", "\u{222F}", .integral),
            ("varnothing", "\u{2205}", .ordinary),
            ("nexists", "\u{2204}", .ordinary),
            ("complement", "\u{2201}", .ordinary),
            ("blacksquare", "\u{25A0}", .ordinary),
            ("checkmark", "\u{2713}", .ordinary),
            ("dag", "\u{2020}", .ordinary), ("ddag", "\u{2021}", .ordinary),
            ("S", "\u{00A7}", .ordinary), ("P", "\u{00B6}", .ordinary),
            ("implies", "\u{27F9}", .relation),
            ("impliedby", "\u{27F8}", .relation),
            ("hookrightarrow", "\u{21AA}", .relation),
            ("hookleftarrow", "\u{21A9}", .relation),
            ("twoheadrightarrow", "\u{21A0}", .relation),
            ("longmapsto", "\u{27FC}", .relation),
            ("therefore", "\u{2234}", .relation),
            ("because", "\u{2235}", .relation),
            ("vdash", "\u{22A2}", .relation), ("dashv", "\u{22A3}", .relation),
            ("lesssim", "\u{2272}", .relation),
            ("gtrsim", "\u{2273}", .relation),
            ("leqslant", "\u{2A7D}", .relation),
            ("geqslant", "\u{2A7E}", .relation),
            ("coloneqq", "\u{2254}", .relation),
            ("triangleq", "\u{225C}", .relation),
            ("nless", "\u{226E}", .relation), ("ngtr", "\u{226F}", .relation),
            ("nleq", "\u{2270}", .relation), ("ngeq", "\u{2271}", .relation),
            ("nmid", "\u{2224}", .relation),
            ("nparallel", "\u{2226}", .relation),
            ("nsim", "\u{2241}", .relation), ("nsimeq", "\u{2244}", .relation),
            ("ncong", "\u{2247}", .relation),
            ("napprox", "\u{2249}", .relation),
            ("nequiv", "\u{2262}", .relation),
            ("notni", "\u{220C}", .relation),
            ("nsubset", "\u{2284}", .relation),
            ("nsupset", "\u{2285}", .relation),
            ("nsubseteq", "\u{2288}", .relation),
            ("nsupseteq", "\u{2289}", .relation),
            ("nprec", "\u{2280}", .relation), ("nsucc", "\u{2281}", .relation),
            ("diamond", "\u{22C4}", .binary),
            // Targets of rewrites above.
            ("mathpdfampersand", "&", .ordinary),
            ("mathpdfbmod", "mod", .binary),
        ]

    private static let symbolsAdded: Void = {
        for symbol in symbols {
            MTMathAtomFactory.add(
                latexSymbol: symbol.name,
                value: atom(symbol.character, symbol.kind))
        }
    }()

    private static func atom(_ character: String, _ kind: Kind) -> MTMathAtom {
        if kind == .integral {
            return MTMathAtomFactory.operatorWithName(character, limits: false)
        }
        // Atoms can't be made directly (the initialiser isn't public), so one
        // is made for a plain character and given the symbol's type and
        // character.
        let atom = MTMathAtomFactory.atom(forCharacter: "|")!
        atom.type =
            kind == .relation
            ? .relation : kind == .binary ? .binaryOperator : .ordinary
        atom.nucleus = character
        return atom
    }
}
