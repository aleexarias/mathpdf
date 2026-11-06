import SwiftUI

struct DoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action)
            .keyboardShortcut(.return, modifiers: .command)
    }
}

struct FontSizeStepper: View {
    @Binding var size: Double
    let range: ClosedRange<Double>

    var body: some View {
        Stepper("Size \(Int(size)) pt", value: $size, in: range, step: 2)
            .fixedSize()
    }
}

struct FinishHint: View {
    var body: some View {
        Text("Esc/⌘↩ to finish.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

extension View {
    /// The look of a `TextEditor` where text is being written.
    func writingArea() -> some View {
        scrollContentBackground(.hidden)
            .padding(4)
            .background(
                .background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}
