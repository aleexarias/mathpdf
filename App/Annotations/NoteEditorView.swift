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
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.body)
                .focused($focused)
                .writingArea()
                .frame(width: 280, height: 140)
            HStack {
                FinishHint()
                Spacer()
                DoneButton(action: done)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
