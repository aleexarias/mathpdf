import MathPDFLaTeX
import SwiftUI

/// Where the user's own LaTeX commands are written, as in a preamble. Saving
/// is what checks them, and what makes them available to formulas.
struct LaTeXCommandsEditor: View {
    @Bindable var library: LaTeXCommandLibrary
    let close: () -> Void
    @FocusState private var focused: Bool

    private static let example = #"""
        % For example:
        \newcommand{\R}{\mathbb{R}}
        \newcommand{\norm}[1]{\left\|#1\right\|}
        \DeclareMathOperator{\Var}{Var}
        """#

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own commands, for formulas in every PDF.")
                .font(.headline)
            if library.readError == nil {
                editor
                status
            } else {
                status
                Spacer()
            }
            Text(
                """
                A formula is drawn with the commands as they were when you \
                entered it. Saving a change applies it to new formulas, and \
                to ones whose text you edit.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut("w")
                Button("Save", action: library.save)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!library.hasUnsavedChanges)
            }
        }
        .padding(16)
        .onAppear { focused = true }
        .onChange(of: library.saved, initial: true) { library.checkSaved() }
    }

    private var editor: some View {
        TextEditor(text: $library.text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .focused($focused)
            .writingArea()
            .overlay(alignment: .topLeading) {
                if library.text.isEmpty {
                    Text(verbatim: Self.example)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(9)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var status: some View {
        if let error = library.readError {
            problem(
                """
                latex-commands.tex can't be read, so it's left as it is. Fix \
                it or move it away, then come back to mathpdf. \(error)
                """)
        } else if let error = library.saveError {
            problem("Your commands couldn't be saved. \(error)")
        } else if !library.issues.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(library.issues, id: \.self) { issue in
                        problem("Line \(issue.line): \(issue.message)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        } else if library.current.count > 0 {
            Text(
                library.current.count == 1
                    ? "1 command" : "\(library.current.count) commands"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func problem(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
}
