import Observation
import SwiftUI

/// The text and size being set in the text box editor; read back when the
/// popover closes.
@MainActor @Observable
final class TextBoxDraft {
    var text: String
    var fontSize: Double

    init(text: String, fontSize: Double) {
        self.text = text
        self.fontSize = fontSize
    }
}

/// The text is shown in the box's font at one size: the size control changes
/// the box on the page, not this.
struct TextBoxEditorView: View {
    @Bindable var draft: TextBoxDraft
    let isNew: Bool
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.custom("Helvetica", size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(4)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .frame(width: 320, height: 110)
            HStack {
                FontSizeStepper(size: $draft.fontSize, range: 6...72)
                Spacer()
                Text(
                    isNew
                        ? "Esc to finish. Empty text boxes are deleted."
                        : "Esc to finish."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                DoneButton(action: done)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
