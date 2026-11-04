import SwiftUI

/// "n of N" with previous, next and clear buttons, or "No matches", while a
/// search is active.
struct SearchResultsBar: View {
    let viewer: Viewer

    var body: some View {
        if !viewer.searchedText.isEmpty {
            HStack(spacing: 2) {
                if let index = viewer.matchIndex {
                    arrowButton(
                        "Previous Match", "chevron.up",
                        help: "Previous Match (⇧⌘G)"
                    ) { viewer.previousMatch() }
                    arrowButton(
                        "Next Match", "chevron.down", help: "Next Match (⌘G)"
                    ) { viewer.nextMatch() }
                    Text("\(index + 1) of \(viewer.matches.count)")
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                } else {
                    Text("No matches").padding(.horizontal, 6)
                }
                Button {
                    viewer.endSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Clear the search")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            // Solid, not translucent, so the controls stand out from the page
            // in light and dark mode.
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .padding(10)
        }
    }

    private func arrowButton(
        _ title: String, _ symbol: String, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .fontWeight(.semibold)
                .imageScale(.large)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .help(help)
    }
}
