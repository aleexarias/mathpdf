import MathPDFCore
import SwiftUI

/// Lets the user copy an existing annotation set onto this PDF, e.g. after the
/// PDF was edited elsewhere and its hash changed. The source set is never
/// modified.
struct RelinkSheet: View {
    let session: DocumentSession
    @Environment(\.dismiss) private var dismiss
    @State private var selection: AnnotationStore.StoredSetSummary.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relink Annotations").font(.headline)
            Text(
                """
                Copy a saved annotation set onto “\(session.fileName)”. The \
                set you pick stays as it is. If the pages changed, \
                annotations may land in the wrong place.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            List(session.relinkCandidates, selection: $selection) {
                CandidateRow(candidate: $0, pageCount: session.pdf?.pageCount)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Relink") {
                    guard
                        let candidate = session.relinkCandidates.first(where: {
                            $0.id == selection
                        })
                    else { return }
                    Task {
                        await session.relink(from: candidate)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { selection = session.relinkCandidates.first?.id }
    }
}

private struct CandidateRow: View {
    let candidate: AnnotationStore.StoredSetSummary
    let pageCount: Int?

    var body: some View {
        let count = candidate.annotationCount
        let saved = candidate.savedAt.formatted(
            date: .abbreviated, time: .shortened)
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.fileNameHint).fontWeight(.medium)
            Text(candidate.pathHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text("\(count) annotation\(count == 1 ? "" : "s")")
                Text("·")
                Text("\(candidate.pageCount) pages")
                if candidate.pageCount != pageCount {
                    Label(
                        "page count differs",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                Text("·")
                Text("saved \(saved)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
