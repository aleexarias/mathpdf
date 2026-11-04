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
