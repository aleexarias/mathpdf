import Testing

@testable import MathPDFLaTeX

/// What can be typed: SwiftMath's own LaTeX plus the commands filled in by
/// LaTeXCompatibility.
@MainActor
struct CompatibilityTests {
    /// Everyday math that must typeset.
    nonisolated static let common: [String] = [
        #"x^2 + y_1 + z_{ij}^{n+1}"#, #"\frac{a+b}{c}"#,
        #"\frac{1}{1+\frac{1}{x}}"#, #"\sqrt{x} \sqrt[3]{x+1}"#,
        #"\binom{n}{k}"#,
        #"\alpha\beta\gamma\delta\epsilon\varepsilon\theta"#,
        #"\lambda\mu\pi\sigma\phi\varphi\omega"#,
        #"\Gamma\Delta\Theta\Lambda\Pi\Sigma\Phi\Psi\Omega"#,
        #"\sum_{n=1}^{\infty} \frac{1}{n^2}"#, #"\prod_{i=1}^{n} x_i"#,
        #"\int_0^1 f(x)\,dx"#, #"\oint_C"#,
        #"\lim_{x \to 0} \frac{\sin x}{x}"#, #"\limsup_{n} a_n \liminf"#,
        #"\left( \frac{a}{b} \right) \left[ x \right]"#,
        #"\left\{ y \right\} \left| x \right|"#,
        #"\langle u, v \rangle"#,
        #"\lfloor x \rfloor \lceil x \rceil"#,
        #"\sin \cos \tan \log \ln \exp \det \arcsin \sinh \gcd"#,
        #"\max_{x} \min \sup \inf \arg\max"#,
        #"\mathbb{R} \mathcal{L} \mathfrak{g} \mathbf{v}"#,
        #"\bm{x} \mathrm{d}x \mathit{abc}"#,
        #"\text{if } x > 0 \text{, else}"#,
        #"\hat{x} \bar{x} \vec{v} \tilde{x} \dot{x} \ddot{x}"#,
        #"\widehat{AB} \widetilde{xy}"#,
        #"\overline{z} \underline{w}"#,
        #"\leq \geq \neq \approx \equiv \sim"#,
        #"\simeq \cong \propto \le \ge \ne"#,
        #"\in \notin \subset \subseteq \supset \cup \cap \emptyset"#,
        #"\forall \exists \neg \land \lor \iff"#,
        #"\to \rightarrow \Rightarrow \leftarrow"#,
        #"\Leftrightarrow \mapsto \Longrightarrow"#,
        #"\pm \mp \times \div \cdot \circ \star \oplus \otimes"#,
        #"\infty \partial \nabla \hbar \ell \Re \Im \aleph"#,
        #"\ldots \cdots \vdots \ddots"#, #"a \, b \; c \quad d \qquad e \! f"#,
        #"f'(x) x^\prime"#, #"\{ x \mid x > 0 \}"#,
        ##"\% \# \$ \_"##, #"30^\circ \angle ABC \perp \parallel"#,
        #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#,
        #"\begin{bmatrix} 1 & 0 \\ 0 & 1 \end{bmatrix}"#,
        #"\begin{vmatrix} a & b \\ c & d \end{vmatrix}"#,
        #"f(x) = \begin{cases} x & x \geq 0 \\ -x & x < 0 \end{cases}"#,
        #"\begin{aligned} a &= b + c \\ d &= e \end{aligned}"#,
        #"\displaystyle \sum_{k=0}^{n} \binom{n}{k} = 2^n"#,
        #"\sum\limits_{i} \int\limits_a^b"#,
        #"\frac{\partial^2 u}{\partial x^2}"#,
        #"e^{-\frac{x^2}{2\sigma^2}}"#, #"\left. \frac{df}{dx} \right|_{x=0}"#,
        #"\mathbf{A}^{-1} \mathbf{A}^\top"#,
        #"\color{#FF0000}{x}"#,
    ]

    /// Commands SwiftMath lacks that are filled in.
    nonisolated static let filledIn: [String] = [
        #"\dfrac{1}{2} \tfrac{1}{2} \cfrac{1}{2} \dfrac12"#,
        #"\iint_D \iiint_V \oiint"#, #"\lVert v \rVert \lvert x \rvert"#,
        #"\left\lVert v \right\rVert"#,
        #"\operatorname{tr}(A) \operatorname{rank} A"#,
        #"\operatorname*{argmax}_x"#,
        #"\boldsymbol{\alpha} \pmb{x} \mathscr{L}"#,
        #"\varnothing \nexists \complement"#, #"\implies \impliedby"#,
        #"\hookrightarrow \twoheadrightarrow \longmapsto"#,
        #"a \bmod n \pmod{n} \mod{n}"#,
        #"\overset{!}{=} \stackrel{\text{def}}{=}"#,
        #"\underset{x}{\arg\min} \overset{\sim}{\to}"#,
        #"\xrightarrow{f} \xleftarrow[g]{f}"#,
        #"\big( \Big[ \bigg\{ \Bigg| \bigl( x \bigr)"#, #"a \& b"#,
        #"\not= \not\in \not< \not\subset \not\equiv \nleq \ngeq \nmid"#,
        #"\lt \gt"#,
        #"\therefore \because \vdash \dashv \checkmark"#,
        #"\lesssim \gtrsim \leqslant \geqslant \coloneqq \triangleq"#,
        #"\begin{array}{cc} 1 & 2 \\ 3 & 4 \end{array}"#,
        #"\begin{align} a &= b \end{align}"#,
        #"\begin{align*} a &= b \\ c &= d \end{align*}"#,
        #"\begin{smallmatrix} a & b \end{smallmatrix}"#,
        #"\begin{dcases} a & x \\ b & y \end{dcases}"#,
        #"\begin{equation} E = mc^2 \end{equation}"#,
        #"\sum_{\substack{i < n \\ j < m}} a_{ij}"#,
        #"x = 1 \tag{1} \label{eq} \nonumber"#,
        #"\color{red}{x} + \textcolor{blue}{y}"#,
        #"\dots \Box \qed \blacksquare \dag \S"#,
    ]

    @Test(arguments: common + filledIn)
    func typesets(_ source: String) {
        let result = LaTeXRenderer.typeset(source, fontSize: 16, color: .black)
        if case .invalid(let message) = result {
            Issue.record("\(source): \(message)")
        }
    }

    @Test(arguments: [
        (#"\cancel{x}"#, #"Command not supported: \cancel"#),
        (#"\boxed{x = 1}"#, #"Command not supported: \boxed"#),
        (#"\overbrace{a+b}^{n}"#, #"Command not supported: \overbrace"#),
        (#"\overrightarrow{AB}"#, #"Command not supported: \overrightarrow"#),
        (#"x + \foo"#, #"Command not supported: \foo"#),
        (#"\not\foo"#, #"Command not supported: \not\foo"#),
        (
            #"\begin{tikzcd} a \end{tikzcd}"#,
            "Environment not supported: tikzcd"
        ),
        (#"\frac{1}{2"#, "Missing closing brace"),
        (#"\operatorname{tr"#, "Missing closing brace"),
        (#"\operatorname"#, #"\operatorname needs an argument."#),
        (
            #"\overset{a}{\frac{1}{2}}"#,
            #"\overset only works over a single symbol or word."#
        ),
    ])
    func explainsWhatIsWrong(_ source: String, message: String) {
        guard
            case .invalid(let actual) = LaTeXRenderer.typeset(
                source, fontSize: 16, color: .black)
        else {
            Issue.record("\(source) typeset")
            return
        }
        #expect(actual == message)
    }

    @Test(arguments: [
        (#"\dfrac{1}{2}"#, #"\frac{1}{2}"#),
        (#"\color{red}{x}"#, #"\color{#FF0000}{x}"#),
        (#"\not=\not\in"#, #"\neq \notin "#),
        (
            #"\begin{align*}a&=b\end{align*}"#,
            #"\begin{aligned}a&=b\end{aligned}"#
        ),
        (
            #"\begin{array}{c|c}1&2\end{array}"#,
            #"\begin{matrix}1&2\end{matrix}"#
        ),
        (#"\pmod{n}"#, #"\quad(\mathrm{mod}\;n)"#),
        (#"\big(x\bigr)"#, "(x)"),
        (#"\text{\dfrac and \lt}"#, #"\text{\dfrac and \lt}"#),
        (
            #"\frac{\lt}{\left\lVert x\right\rVert}"#,
            #"\frac{<}{\left\| x\right\|}"#
        ),
        (#"x \tag{2}"#, #"x \qquad\text{(2)}"#),
    ])
    func rewrites(_ source: String, expected: String) throws {
        #expect(try LaTeXCompatibility.rewrite(source) == expected)
    }

    @Test func sameOperatorNameReusesItsCommand() throws {
        let first = try LaTeXCompatibility.rewrite(#"\operatorname{Var}"#)
        let second = try LaTeXCompatibility.rewrite(#"\operatorname{Var}(X)"#)
        #expect(second == first + "(X)")
        // with limits: another operator
        #expect(
            try LaTeXCompatibility.rewrite(#"\operatorname*{Var}"#) != first)
    }
}
