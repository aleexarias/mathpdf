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

/// A palette colour's name with its swatch, for menus and lists.
struct PaletteLabel: View {
    let entry: Palette.Entry

    var body: some View {
        Label {
            Text(entry.name)
        } icon: {
            Image(nsImage: Palette.swatch(entry.color))
        }
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
                .background.secondary, in: RoundedRectangle.writingArea)
    }

    /// A writing area `height` tall that grows a line at a time, so the line
    /// after the text is always on show, up to three times as tall or as tall
    /// as fits on the screen; then it scrolls. Measured once its text view
    /// has the focus, as typing goes to it.
    func growingHeight(from height: CGFloat, text: String, focused: Bool)
        -> some View
    {
        modifier(GrowingHeight(minimum: height, text: text, focused: focused))
    }
}

extension RoundedRectangle {
    static let writingArea = RoundedRectangle(cornerRadius: 6)
}

private struct GrowingHeight: ViewModifier {
    let minimum: CGFloat
    let text: String
    let focused: Bool
    @State private var height: CGFloat?
    /// Padding and insets around the text, measured before any growing, as
    /// the layout can lag behind `height` while typing.
    @State private var surround: CGFloat?

    private static let mostTimesTaller: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .frame(height: height ?? minimum)
            .onChange(of: text) { fit() }
            .onChange(of: focused) { fit() }
    }

    private func fit() {
        guard focused,
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
            let container = textView.textContainer,
            let scrollView = textView.enclosingScrollView,
            let window = textView.window
        else { return }
        let visible = scrollView.documentVisibleRect.height
        guard surround != nil || visible > 0 else { return }
        let inset = textView.textContainerInset.height
        let surround = surround ?? minimum - visible + 2 * inset
        self.surround = surround
        let current = height ?? minimum
        // the popover grows downwards
        let fitsOnScreen =
            window.frame.maxY - (window.screen?.visibleFrame.minY ?? 0)
            - (window.frame.height - current)
        let tallest = min(minimum * Self.mostTimesTaller, fitsOnScreen)
        let wanted = surround + Self.textHeight(of: textView, in: container)
        height = max(minimum, min(wanted.rounded(.up), tallest))
    }

    /// The text's height with the empty line after it, laid out as the text
    /// view lays it out.
    private static func textHeight(
        of textView: NSTextView, in container: NSTextContainer
    ) -> CGFloat {
        let storage = NSTextStorage(
            attributedString: textView.attributedString())
        storage.append(
            NSAttributedString(
                string: "\n", attributes: textView.typingAttributes))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let measuring = NSTextContainer(
            size: CGSize(
                width: container.size.width,
                height: .greatestFiniteMagnitude))
        measuring.lineFragmentPadding = container.lineFragmentPadding
        layout.addTextContainer(measuring)
        layout.ensureLayout(for: measuring)
        return layout.usedRect(for: measuring).height
    }
}
