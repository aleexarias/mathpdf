import MathPDFLaTeX
import Observation
import SwiftUI

/// What's being typed in the LaTeX editor; read back when the popover closes.
@MainActor @Observable
final class LaTeXDraft {
    var source: String {
        didSet { if source != oldValue { isErrorCurrent = false } }
    }
    var fontSize: Double {
        didSet { if fontSize != oldValue { isErrorCurrent = false } }
    }
    /// What was wrong the last time the user tried to finish. It stays on show
    /// while they fix it.
    private(set) var error: String?
    /// The error was shown and nothing has changed since: trying to finish
    /// again gives up on the formula. After any change, the next try checks it
    /// afresh.
    private(set) var isErrorCurrent = false
    /// The last try to finish, so one click that reaches both the popover and
    /// the page counts once.
    @ObservationIgnored var lastAttempt: TimeInterval?
    @ObservationIgnored private let entered: EnteredExpansion

    init(source: String, fontSize: Double, expanded: String? = nil) {
        self.source = source
        self.fontSize = fontSize
        entered = EnteredExpansion(text: source, expanded: expanded)
    }

    /// What's drawn for the source as it is now.
    func expansion(using commands: LaTeXCommands) throws(LaTeXProblem)
        -> String
    {
        try entered.expansion(of: source, commands.expansion(of:))
    }

    func show(error: String) {
        self.error = error
        isErrorCurrent = true
    }
}

struct LaTeXEditorView: View {
    @Bindable var draft: LaTeXDraft
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft.source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .writingArea()
                .overlay {
                    if draft.isErrorCurrent {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(
                            .red.opacity(0.7))
                    }
                }
                .frame(height: 64)

            if let error = draft.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(
                            draft.isErrorCurrent
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.secondary))
                    if draft.isErrorCurrent {
                        Text("Fix the formula or quit editing.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                FontSizeStepper(size: $draft.fontSize, range: 8...48)
                Spacer()
                FinishHint()
                DoneButton(action: done)
            }
        }
        .padding(12)
        .frame(width: 400)
        .onAppear { focused = true }
    }
}
