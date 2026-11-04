import SwiftUI

/// The annotations as they are now beside an earlier version, the versions
/// listed by day, and a way to go back to one: to its annotations, or to its
/// pages with today's annotations. Restoring can be undone and is saved as a
/// new version, so it never loses anything.
struct VersionBrowser: View {
    let session: DocumentSession
    let startPage: Int
    let close: () -> Void
    @State private var history: VersionHistory
    @State private var scrollLink = PreviewScrollLink()

    init(session: DocumentSession, startPage: Int, close: @escaping () -> Void)
    {
        self.session = session
        self.startPage = startPage
        self.close = close
        _history = State(initialValue: VersionHistory(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                pane(
                    title: "Now",
                    detail: summary(
                        pages: session.pdf?.pageCount ?? 0,
                        annotations: session.annotations.count)
                ) {
                    AnnotatedPDFPreview(
                        data: session.data, documentHash: currentHash,
                        annotations: session.annotations,
                        startPage: startPage,
                        link: scrollLink, role: .follower)
                }
                Divider()
                pane(title: selectedTitle, detail: selectedDetail) {
                    HStack(spacing: 0) {
                        if let annotations = history.selected?.annotations {
                            AnnotatedPDFPreview(
                                data: history.selected?.pdf ?? session.data,
                                documentHash: history.selected?.pageOrder?
                                    .documentHash ?? currentHash,
                                annotations: annotations,
                                startPage: startPage,
                                link: scrollLink, role: .leader)
                        } else {
                            placeholder
                        }
                        LinkedScrollBar(link: scrollLink)
                            .frame(width: LinkedScroller.width)
                    }
                }
                Divider()
                versionList
                    .frame(width: 250)
            }
            Divider()
            HStack {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(
                    history.selected?.pageOrder == nil
                        ? "Restore This Version" : "Restore These Pages"
                ) { restore() }
                .disabled(!canRestore)
            }
            .padding(12)
        }
        .frame(
            minWidth: 900, idealWidth: 1150, minHeight: 560, idealHeight: 760
        )
        .task { await history.load() }
    }

    private func pane(
        title: String, detail: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Divider()
            content()
        }
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            if history.isLoading {
                ProgressView()
            } else if history.selected?.isDamaged == true {
                Label(
                    "This version couldn't be read.",
                    systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Viewer.pageBackground))
    }

    private var versionList: some View {
        List(selection: $history.selection) {
            ForEach(history.sections) { section in
                Section(section.title) {
                    ForEach(section.versions) { version in
                        row(version).tag(version.id)
                    }
                }
            }
        }
    }

    private func row(_ version: VersionHistory.Version) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let date = version.date {
                    Text(date.formatted(date: .omitted, time: .standard))
                } else {
                    Text(
                        history.hasEarlierPages
                            ? "Without annotations" : "Original PDF")
                }
                if version.pageOrder != nil {
                    tag("Earlier pages")
                } else if version.annotations != nil,
                    history.isSameAsNow(version)
                {
                    tag("Same as now")
                }
            }
            Group {
                if version.isDamaged {
                    Text("Couldn't be read").foregroundStyle(.red)
                } else if version.annotations != nil {
                    Text(summary(version))
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private var currentHash: String {
        session.annotationSet?.documentHash ?? ""
    }

    private var selectedTitle: String {
        guard let version = history.selected, let date = version.date else {
            return history.selected == nil
                ? "Earlier Version" : "First Version"
        }
        return version.pageOrder == nil
            ? "Saved \(VersionHistory.when(date))"
            : "Pages before the change \(VersionHistory.when(date))"
    }

    private var selectedDetail: String {
        guard let version = history.selected, version.annotations != nil
        else { return " " }
        return summary(version)
    }

    private var footnote: String {
        if history.selected?.pageOrder != nil {
            return """
                Restoring puts the pages back as they were and keeps today's \
                annotations on them. You can undo it.
                """
        }
        return """
            Restoring replaces the annotations shown on the left. You can \
            undo it, and the current ones stay in this list.
            """
    }

    private var canRestore: Bool {
        guard let version = history.selected, version.annotations != nil,
            !version.isDamaged
        else { return false }
        if version.pageOrder != nil { return session.canChangePages }
        return session.canEdit && !history.isSameAsNow(version)
    }

    private func restore() {
        guard let version = history.selected,
            let annotations = version.annotations
        else { return }
        if case .pageOrder(let order, let earlier) = version.kind {
            let session = session
            Task { await session.restorePages(order, earlier: earlier) }
        } else {
            session.restore(annotations)
            // saved as a new version right away
            Task { await session.flush() }
        }
        close()
    }

    /// A saved version is shown on today's pages; an earlier page order has
    /// its own.
    private func summary(_ version: VersionHistory.Version) -> String {
        summary(
            pages: version.pageOrder?.identity.pageIDs.count
                ?? session.pdf?.pageCount ?? 0,
            annotations: version.annotations?.count ?? 0,
            leftOut: version.leftOut)
    }

    /// "8 pages · 3 annotations". Annotations of a version on pages that are
    /// gone now can't be shown, and that's said too.
    private func summary(pages: Int, annotations: Int, leftOut: Int = 0)
        -> String
    {
        let marks =
            switch annotations {
            case 0: "no annotations"
            case 1: "1 annotation"
            default: "\(annotations) annotations"
            }
        let text = "\(pages == 1 ? "1 page" : "\(pages) pages") · \(marks)"
        return leftOut == 0 ? text : "\(text), \(leftOut) on removed pages"
    }
}
