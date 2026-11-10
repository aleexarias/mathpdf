import MathPDFLaTeX
import Observation
import SwiftUI

/// The text and size being set in the text box editor; read back when the
/// popover closes.
@MainActor @Observable
final class TextBoxDraft {
    var text: String
    var fontSize: Double
    @ObservationIgnored private let entered: EnteredExpansion

    init(text: String, fontSize: Double, expanded: String? = nil) {
        self.text = text
        self.fontSize = fontSize
        entered = EnteredExpansion(text: text, expanded: expanded)
    }

    /// What's drawn for the text as it is now: its formulas expanded.
    func expansion(using commands: LaTeXCommands) throws(LaTeXProblem)
        -> String
    {
        try entered.expansion(of: text, commands.expansion(ofFormulasIn:))
    }
}

/// The text is shown in the box's font at one size: the size control changes
/// the box on the page, not this.
struct TextBoxEditorView: View {
    @Bindable var draft: TextBoxDraft
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.custom("Helvetica", size: 13))
                .focused($focused)
                .writingArea()
                .frame(width: 320, height: 110)
            HStack {
                FontSizeStepper(size: $draft.fontSize, range: 6...72)
                Spacer()
                FinishHint()
                DoneButton(action: done)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
