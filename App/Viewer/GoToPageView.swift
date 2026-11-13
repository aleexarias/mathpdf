import SwiftUI

/// Asks for a page number and goes to that page, at the current zoom.
struct GoToPageView: View {
    let viewer: Viewer
    @State private var number = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Go to page")
            TextField("1–\(viewer.pageCount)", text: $number)
                .frame(width: 72)
                .focused($focused)
                .onSubmit(go)
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func go() {
        let page = Int(number.trimmingCharacters(in: .whitespaces))
        guard let page, viewer.go(toPage: page - 1) else {
            return NSSound.beep()
        }
        viewer.isChoosingPage = false
    }
}
