import MathPDFCore
import Observation
import SwiftUI

/// The saved versions of a PDF's annotations, one per snapshot, newest first,
/// and last the first version: the PDF as it is, with no annotations.
@MainActor @Observable
final class VersionHistory {
    struct Version: Identifiable {
        enum ID: Hashable {
            case original
            case snapshot(URL)
        }

        /// Nil for the first version, which isn't saved: the PDF itself.
        let snapshot: SnapshotInfo?
        /// Read in the background after the list appears; nil until then.
        var annotations: [Annotation]?
        var isDamaged = false
        var id: ID { snapshot.map { .snapshot($0.url) } ?? .original }
        var isOriginal: Bool { snapshot == nil }

        static let original = Version(snapshot: nil, annotations: [])
    }

    /// Saved versions grouped by day, then the first version on its own.
    struct Section: Identifiable {
        let id: Date?
        let title: String
        let versions: [Version]
    }

    private(set) var versions: [Version] = []
    private(set) var isLoading = true
    var selection: Version.ID?
    private let session: DocumentSession

    init(session: DocumentSession) {
        self.session = session
    }

    var selected: Version? { versions.first { $0.id == selection } }

    var sections: [Section] {
        let calendar = Calendar.current
        var saved: [Date: [Version]] = [:]
        for version in versions {
            guard let snapshot = version.snapshot else { continue }
            saved[calendar.startOfDay(for: snapshot.date), default: []]
                .append(version)
        }
        let days = saved.sorted { $0.key > $1.key }.map { day, versions in
            Section(
                id: day, title: Self.title(forDay: day), versions: versions)
        }
        let first = versions.filter(\.isOriginal)
        guard !first.isEmpty else { return days }
        return days + [
            Section(id: nil, title: "First Version", versions: first)
        ]
    }

    /// Saves what's pending first, so the newest version is what's on screen
    /// now. The list appears straight away; each version's annotations are
    /// read after it.
    func load() async {
        await session.flush()
        var snapshots: [SnapshotInfo] = []
        if let hash = session.annotationSet?.documentHash {
            snapshots = await Persistence.store.snapshots(documentHash: hash)
        }
        versions = snapshots.map { Version(snapshot: $0) } + [.original]
        for index in versions.indices {
            if let snapshot = versions[index].snapshot {
                if let set = try? await Persistence.store.readSnapshot(
                    snapshot)
                {
                    versions[index].annotations = set.annotations
                } else {
                    versions[index].isDamaged = true
                }
            }
            // Start on the newest version that's different from now.
            if selection == nil, let annotations = versions[index].annotations,
                annotations != session.annotations
            {
                selection = versions[index].id
            }
        }
        if selection == nil { selection = versions.first?.id }
        isLoading = false
    }

    func isSameAsNow(_ version: Version) -> Bool {
        version.annotations == session.annotations
    }

    /// "Today", "Yesterday", "Monday 2 November", or with the year when it
    /// isn't this year's.
    static func title(forDay day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let sameYear =
            calendar.component(.year, from: day)
            == calendar.component(.year, from: .now)
        return sameYear
            ? day.formatted(.dateTime.weekday(.wide).day().month(.wide))
            : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    /// "today at 14:32", "yesterday at 09:10", "on 2 November 2026 at 18:05".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "on \(date.formatted(date: .long, time: .omitted)) at \(time)"
    }
}

/// The annotations as they are now beside an earlier version, the versions
/// listed by day, and a way to go back to one. Restoring can be undone and is
/// saved as a new version, so it never loses anything.
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
                pane(title: "Now", detail: count(session.annotations.count)) {
                    AnnotatedPDFPreview(
                        data: session.data, annotations: session.annotations,
                        startPage: startPage,
                        link: scrollLink, role: .follower)
                }
                Divider()
                pane(title: selectedTitle, detail: selectedDetail) {
                    if let annotations = history.selected?.annotations {
                        AnnotatedPDFPreview(
                            data: session.data, annotations: annotations,
                            startPage: startPage,
                            link: scrollLink, role: .leader)
                    } else {
                        placeholder
                    }
                }
                Divider()
                versionList
                    .frame(width: 250)
            }
            Divider()
            HStack {
                Text(
                    """
                    Restoring replaces the annotations shown on the left. \
                    You can undo it, and the current ones stay in this list.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Restore This Version") { restore() }
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
                if let snapshot = version.snapshot {
                    Text(
                        snapshot.date.formatted(
                            date: .omitted, time: .standard))
                } else {
                    Text("Original PDF")
                }
                if version.annotations != nil, history.isSameAsNow(version) {
                    tag("Same as now")
                }
            }
            Group {
                if version.isDamaged {
                    Text("Couldn't be read").foregroundStyle(.red)
                } else if let annotations = version.annotations {
                    Text(count(annotations.count))
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

    private var selectedTitle: String {
        guard let version = history.selected else { return "Earlier Version" }
        guard let snapshot = version.snapshot else { return "First Version" }
        return "Saved \(VersionHistory.when(snapshot.date))"
    }

    private var selectedDetail: String {
        guard let version = history.selected else { return " " }
        if version.isOriginal {
            return "The original PDF, without annotations"
        }
        return version.annotations.map { count($0.count) } ?? " "
    }

    private var canRestore: Bool {
        guard session.canEdit, let version = history.selected,
            version.annotations != nil
        else { return false }
        return !history.isSameAsNow(version)
    }

    private func restore() {
        guard let annotations = history.selected?.annotations else { return }
        session.restore(annotations)
        Task { await session.flush() }  // saved as a new version right away
        close()
    }

    private func count(_ n: Int) -> String {
        switch n {
        case 0: "No annotations"
        case 1: "1 annotation"
        default: "\(n) annotations"
        }
    }
}
