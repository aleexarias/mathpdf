import MathPDFCore
import MathPDFRendering
import SwiftUI

/// The annotations sidebar: every item, grouped by page in reading order.
/// Clicking one selects it and scrolls to it.
struct AnnotationList: View {
    let session: DocumentSession
    let editor: AnnotationEditor

    var body: some View {
        let items = Item.items(from: session.annotations)
        if items.isEmpty {
            ContentUnavailableView(
                "No Annotations", systemImage: "highlighter",
                description: Text(
                    """
                    Select text and choose Highlight, Underline or Note, or \
                    press the LaTeX or Text button.
                    """
                ))
        } else {
            List(selection: selection) {
                ForEach(
                    Dictionary(grouping: items, by: \.pageIndex).sorted {
                        $0.key < $1.key
                    }, id: \.key
                ) { page, pageItems in
                    Section("Page \(page + 1)") {
                        ForEach(pageItems) { item in
                            row(item)
                                .tag(item.id)
                                .contextMenu {
                                    Button("Delete") {
                                        session.deleteItem(item.id)
                                    }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var selection: Binding<UUID?> {
        Binding {
            session.selection
        } set: { itemID in
            if let itemID {
                editor.reveal(itemID)
            } else {
                session.select(nil)
            }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.symbol)
                .foregroundStyle(Color(nsColor: item.color.nsColor))
                .frame(width: 16)
            Text(description(of: item))
                .lineLimit(3)
                .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func description(of item: Item) -> String {
        switch item.annotations[0].kind {
        case .underline, .highlight:
            let text = item.annotations.map(editor.text(under:)).joined(
                separator: " ")
            return text.isEmpty ? "(no text)" : text
        case .note(let text, _):
            return text.isEmpty ? "(empty note)" : text
        case .latex(let source, _, _):
            return source
        case .textBox(let text, _):
            return text
        }
    }

    /// One row: a single annotation, or all lines of a multi-line markup.
    struct Item: Identifiable {
        let id: UUID
        let annotations: [Annotation]

        var pageIndex: Int { annotations[0].pageIndex }
        var color: RGBAColor { annotations[0].color }

        var symbol: String {
            switch annotations[0].kind {
            case .underline: "underline"
            case .highlight: "highlighter"
            case .note: "text.bubble"
            case .latex: "function"
            case .textBox: "character.textbox"
            }
        }

        /// Items in reading order: by page, then top to bottom, then left to
        /// right, then oldest first.
        static func items(from annotations: [Annotation]) -> [Item] {
            Dictionary(grouping: annotations, by: \.itemID).map {
                Item(id: $0, annotations: $1)
            }.sorted { a, b in
                let (pa, pb) = (a.annotations[0], b.annotations[0])
                if pa.pageIndex != pb.pageIndex {
                    return pa.pageIndex < pb.pageIndex
                }
                if abs(pa.bounds.maxY - pb.bounds.maxY) > 1 {
                    return pa.bounds.maxY > pb.bounds.maxY
                }
                if abs(pa.bounds.minX - pb.bounds.minX) > 1 {
                    return pa.bounds.minX < pb.bounds.minX
                }
                return (pa.createdAt, pa.id.uuidString) < (
                    pb.createdAt, pb.id.uuidString
                )  // a stable order for ties
            }
        }
    }
}
