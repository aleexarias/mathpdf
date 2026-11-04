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

    init(source: String, fontSize: Double) {
        self.source = source
        self.fontSize = fontSize
    }

    func show(error: String) {
        self.error = error
        isErrorCurrent = true
    }
}

struct LaTeXEditorView: View {
    @Bindable var draft: LaTeXDraft
    let isNew: Bool
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $draft.source)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(4)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 6)
                )
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
                        let outcome =
                            isNew
                            ? "delete this formula" : "discard this change"
                        Text(
                            """
                            Fix it, or press Esc or click away again to \
                            \(outcome).
                            """
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                FontSizeStepper(size: $draft.fontSize, range: 8...48)
                Spacer()
                Text("Esc to finish. Empty formulas are deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DoneButton(action: done)
            }
        }
        .padding(12)
        .frame(width: 400)
        .onAppear { focused = true }
    }
}
