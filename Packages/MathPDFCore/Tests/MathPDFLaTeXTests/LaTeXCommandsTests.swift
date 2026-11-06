import Testing

@testable import MathPDFLaTeX

/// The user's own commands: what can be defined, and how formulas expand.
@MainActor
struct LaTeXCommandsTests {
    private let real = #"\newcommand{\R}{\mathbb{R}}"#
    private let norm = #"\newcommand{\norm}[1]{\|#1\|}"#

    private func issues(_ definitions: String) -> [LaTeXCommands.Issue] {
        LaTeXCommands(definitions: definitions).issues
    }

    @Test(arguments: [
        (#"\newcommand{\R}{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\renewcommand{\R}{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\providecommand{\R}{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\newcommand*{\R}{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\newcommand\R{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\newcommand{ \R } {\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\def\R{\mathbb{R}}"#, #"\R^n"#, #"\mathbb{R}^n"#),
        (#"\def\norm#1{\|#1\|}"#, #"\norm{x}"#, #"\|x\|"#),
        (#"\newcommand{\pow}[2]{#2^#1}"#, #"\pow{a}{b}"#, "b^a"),
        (#"\newcommand{\norm}[1]{\|#1\|}"#, #"\norm x"#, #"\|x\|"#),
        (#"\newcommand{\norm}[1]{\|#1\|}"#, #"\norm\alpha"#, #"\|\alpha\|"#),
        (#"\newcommand{\Lp}[2][p]{L^#1(#2)}"#, #"\Lp{X}"#, "L^p(X)"),
        (#"\newcommand{\Lp}[2][p]{L^#1(#2)}"#, #"\Lp[2]{X}"#, "L^2(X)"),
        (
            #"\DeclareMathOperator{\Var}{Var}"#, #"\Var(X)"#,
            #"\operatorname{Var}(X)"#
        ),
        (
            #"\DeclareMathOperator*{\argmax}{arg\,max}"#, #"\argmax"#,
            #"\operatorname*{arg\,max}"#
        ),
    ])
    func definitionsExpand(_ example: (String, String, String)) throws {
        let commands = LaTeXCommands(definitions: example.0)
        #expect(commands.issues.isEmpty)
        #expect(try commands.expansion(of: example.1) == example.2)
    }

    @Test func definitionsCanSpanLinesAndHaveComments() throws {
        let commands = LaTeXCommands(
            definitions: #"""
                % number sets
                \newcommand{\R}{\mathbb{R}} % the reals

                \newcommand{\pair}[2]{
                  (#1, #2)
                }
                """#)
        #expect(commands.issues.isEmpty)
        #expect(commands.count == 2)
        #expect(try commands.expansion(of: #"\R"#) == #"\mathbb{R}"#)
    }

    @Test func commandsCanUseCommandsAndBeUsedInArguments() throws {
        let commands = LaTeXCommands(
            definitions: real + norm + #"\newcommand{\Rn}{\R^n}"#)
        #expect(try commands.expansion(of: #"\Rn"#) == #"\mathbb{R}^n"#)
        #expect(
            try commands.expansion(of: #"\norm{\R}"#) == #"\|\mathbb{R}\|"#)
        #expect(
            try commands.expansion(of: #"\norm{\norm{x}}"#) == #"\|\|x\|\|"#)
    }

    @Test(arguments: [
        #"\text{\R}"#, #"\textbf{ \R }"#, #"\alpha\\\,\{\}"#,
        #"\begin{matrix}a\end{matrix}"#, #"\unknown{x}"#, "plain x^2",
        #"\"#,
    ])
    func everythingElseIsLeftAsTyped(_ source: String) throws {
        let commands = LaTeXCommands(definitions: real)
        #expect(try commands.expansion(of: source) == source)
    }

    /// `\alpha` followed by `x` must not read as `\alphax`.
    @Test(arguments: [
        (#"\newcommand{\f}[1]{\alpha#1}"#, #"\f{x}"#, #"\alpha x"#),
        (#"\newcommand{\f}[1]{#1x}"#, #"\f{\alpha}"#, #"\alpha x"#),
        (#"\newcommand{\f}[1]{#1}"#, #"\f{\alpha}y"#, #"\alpha y"#),
        (#"\newcommand{\f}{\alpha}"#, #"\f{}y"#, #"\alpha{}y"#),
        (
            #"\newcommand{\f}{\alpha}\newcommand{\g}{y}"#, #"\f\g"#,
            #"\alpha y"#
        ),
        (##"\newcommand{\f}[1]{\\#1}"##, #"\f{x}"#, #"\\x"#),
        (##"\newcommand{\f}[1]{\\ab#1}"##, #"\f{x}"#, #"\\abx"#),
        (#"\newcommand{\f}[1]{a#1b}"#, #"\f{x}"#, "axb"),
    ])
    func tokensStaySeparate(_ example: (String, String, String)) throws {
        let commands = LaTeXCommands(definitions: example.0)
        #expect(try commands.expansion(of: example.1) == example.2)
    }

    @Test func hashesInDefinitions() throws {
        let commands = LaTeXCommands(
            definitions: ##"\newcommand{\a}[1]{\#1 ## #1}"##)
        #expect(commands.issues.isEmpty)
        #expect(try commands.expansion(of: #"\a{x}"#) == ##"\#1 # x"##)
    }

    @Test func aMissingArgumentIsAProblem() {
        let commands = LaTeXCommands(definitions: norm)
        #expect(throws: LaTeXProblem(message: #"\norm needs an argument."#)) {
            try commands.expansion(of: #"\norm"#)
        }
    }

    @Test(arguments: [
        #"\newcommand{\a}{\a}"#,
        #"\newcommand{\a}{\b}\newcommand{\b}{\a}"#,
        #"\newcommand{\a}{\a\a}"#,
        #"\newcommand{\a}[1]{\a{#1}}"#,
        #"\newcommand{\a}[1]{\a{#1#1}}"#,
    ])
    func aCommandUsingItselfIsAProblem(_ definitions: String) throws {
        let commands = LaTeXCommands(definitions: definitions)
        let problem = #expect(throws: LaTeXProblem.self) {
            try commands.expansion(of: #"\a{x}"#)
        }
        #expect(problem?.message.contains("keeps expanding") == true)
    }

    /// Thirty steps of doubling would be a billion copies, without any command
    /// using itself.
    @Test func definitionsThatKeepDoublingAreAProblem() {
        let names = (0...30).map { "c" + String(repeating: "x", count: $0) }
        let definitions = zip(names, names.dropFirst()).map { name, next in
            "\\newcommand{\\\(name)}{\\\(next)\\\(next)}"
        }
        let commands = LaTeXCommands(
            definitions: definitions.joined(separator: "\n"))
        #expect(throws: LaTeXProblem.self) {
            try commands.expansion(of: #"\c"#)
        }
    }

    @Test(arguments: [
        (#"\usepackage{amsmath}"#, "\\usepackage isn't a command definition."),
        ("some text", "This isn't a command definition."),
        (
            #"\newcommand{R}{x}"#,
            #"\newcommand needs a command name, like \R."#
        ),
        (#"\newcommand{\R}"#, #"\R needs its definition in braces."#),
        (#"\newcommand{\begin}{x}"#, #"\begin can't be redefined."#),
        (#"\newcommand{\a}[1]{#2}"#, #"\a uses #2 but has 1 argument."#),
        (#"\newcommand{\a}{#1}"#, #"\a uses #1 but has 0 arguments."#),
        (#"\newcommand{\a}[10]{x}"#, #"\a can have from 0 to 9 arguments."#),
        (#"\newcommand{\a}[0][d]{x}"#, #"\a has a default but no arguments."#),
        (#"\newcommand{\a}{\frac{1}"#, "Missing closing brace"),
    ])
    func whatCantBeReadIsReported(_ example: (String, String)) {
        #expect(issues(example.0).map(\.message) == [example.1])
    }

    /// One bad line doesn't stop the others, and is reported where it is.
    @Test func theRestStillWorksAroundAnIssue() throws {
        let commands = LaTeXCommands(
            definitions: """
                \(real)
                \\usepackage{amsmath}
                \\newcommand{\\broken}{\\frac{1}
                \(norm)
                """)
        #expect(commands.issues.map(\.line) == [2, 3])
        #expect(commands.count == 2)
        #expect(try commands.expansion(of: #"\norm{x}"#) == #"\|x\|"#)
    }

    @Test func definingACommandAgain() throws {
        let renewed = LaTeXCommands(
            definitions: real + #"\renewcommand{\R}{R}"#)
        #expect(renewed.issues.isEmpty)
        #expect(try renewed.expansion(of: #"\R"#) == "R")

        let provided = LaTeXCommands(
            definitions: real + #"\providecommand{\R}{R}"#)
        #expect(provided.issues.isEmpty)
        #expect(try provided.expansion(of: #"\R"#) == #"\mathbb{R}"#)

        let twice = LaTeXCommands(definitions: real + #"\newcommand{\R}{R}"#)
        #expect(
            twice.issues.map(\.message)
                == [#"\R is defined twice: use \renewcommand."#])
        #expect(try twice.expansion(of: #"\R"#) == "R")
    }

    // MARK: With typesetting

    @Test func aCommandThatCantBeTypesetIsFlagged() {
        let commands = LaTeXCommands(
            definitions: """
                \(real)
                \\newcommand{\\b}[1]{\\boxed{#1}}
                \\newcommand{\\loop}{\\loop}
                \\newcommand{\\Lp}[2][p]{L^#1(#2)}
                """)
        let flagged = commands.typesetIssues().sorted { $0.line < $1.line }
        #expect(flagged.map(\.line) == [2, 3])
        #expect(flagged[0].message == #"\b: Command not supported: \boxed"#)
        #expect(flagged[1].message.contains("keeps expanding"))
    }

    /// Commands go in before the compatibility layer, so they can use what it
    /// adds, and replace what it or SwiftMath already has.
    @Test func commandsWorkWithWhatsAlreadyThere() throws {
        let commands = LaTeXCommands(
            definitions: #"""
                \newcommand{\half}{\dfrac12}
                \renewcommand{\dfrac}[2]{#1/#2}
                \renewcommand{\vec}[1]{\mathbf{#1}}
                """#)
        #expect(commands.typesetIssues().isEmpty)
        #expect(try commands.expansion(of: #"\half"#) == "1/2")
        #expect(try commands.expansion(of: #"\vec{x}"#) == #"\mathbf{x}"#)

        let usingLayer = LaTeXCommands(
            definitions: #"\newcommand{\half}{\tfrac12}"#)
        let expanded = try usingLayer.expansion(of: #"\half"#)
        guard
            case .formula = LaTeXRenderer.typeset(
                expanded, fontSize: 16, color: .black)
        else {
            Issue.record("\(expanded) didn't typeset")
            return
        }
    }
}
