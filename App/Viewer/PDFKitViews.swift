import PDFKit
import SwiftUI

/// Hosts a window's PDFView, which its `Viewer` owns and configures.
struct PDFKitView: NSViewRepresentable {
    let pdfView: AnnotationPDFView

    func makeNSView(context: Context) -> AnnotationPDFView { pdfView }
    func updateNSView(_ nsView: AnnotationPDFView, context: Context) {}

    /// Take the space offered. Otherwise SwiftUI sizes the view to its content
    /// (the whole document), which overflows the window.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: AnnotationPDFView,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }
}

/// The toolbar search field. A native NSSearchField rather than a SwiftUI
/// TextField: in a toolbar, SwiftUI's focus handling and focus ring don't keep
/// up when the toolbar resizes.
struct SearchField: NSViewRepresentable {
    let viewer: Viewer

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        // search on Return, not on every keystroke
        field.sendsWholeSearchString = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.delegate = context.coordinator
        viewer.searchField = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(viewer: viewer) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        let viewer: Viewer

        init(viewer: Viewer) { self.viewer = viewer }

        @objc func submit(_ field: NSSearchField) {
            viewer.submitSearch(field.stringValue)
            // Return ends editing and leaves the focus on the window. Put the
            // cursor back at the end of the text, so Return again goes to the
            // next match and typing refines the search.
            guard !field.stringValue.isEmpty else { return }
            Task { @MainActor [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(
                    location: (field.stringValue as NSString).length, length: 0
                )
            }
        }

        /// Esc ends the search and leaves the field (instead of only emptying
        /// it).
        func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:))
            else { return false }
            viewer.leaveSearch()
            return true
        }

        /// Deleting all the text clears the search right away, without needing
        /// Return.
        func controlTextDidChange(_ notification: Notification) {
            if (notification.object as? NSSearchField)?.stringValue.isEmpty
                == true
            {
                viewer.clearSearch()
            }
        }
    }
}
