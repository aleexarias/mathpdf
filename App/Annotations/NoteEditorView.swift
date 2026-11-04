import Observation
import SwiftUI

/// The text being written in the note editor; read back when the popover
/// closes.
@MainActor @Observable
final class NoteDraft {
    var text: String

    init(text: String) { self.text = text }
}

struct NoteEditorView: View {
    @Bindable var draft: NoteDraft
    let isNew: Bool
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(4)
                .background(
                    .background.secondary,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .frame(width: 280, height: 140)
            HStack {
                Text(
                    isNew
                        ? "Esc to finish. Empty notes are discarded."
                        : "Esc to finish."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                DoneButton(action: done)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
