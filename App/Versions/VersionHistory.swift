import Foundation
import MathPDFCore
import Observation

/// The versions of a document, newest first: its annotations as saved,
/// shown on today's pages even when saved before a page change, and its
/// earlier page orders, shown with today's annotations. Last comes the first
/// version: the PDF as it is, with no annotations.
@MainActor @Observable
final class VersionHistory {
    struct Version: Identifiable {
        enum Kind {
            /// Saved annotations, and the IDs of the pages they were on.
            case snapshot(SnapshotInfo, pages: [UUID])
            /// An earlier page order, and the annotations it had when it
            /// was left.
            case pageOrder(AnnotationStore.PageOrder, earlier: [Annotation])
            case original
        }

        enum ID: Hashable {
            case original
            case snapshot(URL)
            case pageOrder(String)
        }

        let kind: Kind
        /// Read in the background after the list appears; nil until then.
        var annotations: [Annotation]?
        /// An earlier page order's PDF; the others show the PDF as it is.
        var pdf: Data?
        /// Annotations of this version on pages that are gone now.
        var leftOut = 0
        var isDamaged = false

        var id: ID {
            switch kind {
            case .snapshot(let snapshot, _): .snapshot(snapshot.url)
            case .pageOrder(let order, _): .pageOrder(order.documentHash)
            case .original: .original
            }
        }

        var date: Date? {
            switch kind {
            case .snapshot(let snapshot, _): snapshot.date
            case .pageOrder(let order, _): order.leftAt
            case .original: nil
            }
        }

        var isOriginal: Bool { id == .original }

        var pageOrder: AnnotationStore.PageOrder? {
            if case .pageOrder(let order, _) = kind { return order }
            return nil
        }
    }

    /// Saved versions grouped by day, then the first version on its own.
    struct Section: Identifiable {
        let id: Date?
        let title: String
        let versions: [Version]
    }

    private(set) var versions: [Version] = []
    private(set) var isLoading = true
    /// Whether the pages were ever changed, so the PDF as it is now isn't
    /// the original.
    private(set) var hasEarlierPages = false
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
            guard let date = version.date else { continue }
            saved[calendar.startOfDay(for: date), default: []].append(version)
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
    /// now. The list appears straight away; each version is read after it.
    func load() async {
        await session.flush()
        guard let set = session.annotationSet,
            let identity = session.pageIdentity
        else {
            versions = [Version(kind: .original, annotations: [])]
            selection = .original
            isLoading = false
            return
        }
        versions =
            await list(of: set.documentHash, identity: identity)
            + [Version(kind: .original, annotations: [])]
        for index in versions.indices {
            versions[index] = await read(
                versions[index], onto: identity.pageIDs)
            // Start on the newest version that's different from now.
            if selection == nil, versions[index].annotations != nil,
                !isSameAsNow(versions[index])
            {
                selection = versions[index].id
            }
        }
        if selection == nil { selection = versions.first?.id }
        isLoading = false
    }

    /// The annotation versions of every page order of the document, and the
    /// earlier page orders whose PDFs are kept, newest first.
    private func list(of hash: String, identity: PageIdentity) async
        -> [Version]
    {
        let store = Persistence.store
        let others = await store.pageOrders(of: identity.documentID)
            .filter { $0.documentHash != hash }
        var list = await store.snapshots(documentHash: hash).map {
            Version(kind: .snapshot($0, pages: identity.pageIDs))
        }
        for order in others {
            list += await store.snapshots(documentHash: order.documentHash)
                .map {
                    Version(kind: .snapshot($0, pages: order.identity.pageIDs))
                }
        }
        let kept = others.filter { $0.pdfURL != nil }
        hasEarlierPages = !kept.isEmpty
        for order in kept {
            let earlier =
                await store.newestSet(documentHash: order.documentHash)?
                .annotations ?? []
            list.append(Version(kind: .pageOrder(order, earlier: earlier)))
        }
        return list.sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
    }

    /// Reads a version's annotations and puts them on today's pages, `now`.
    private func read(_ version: Version, onto now: [UUID]) async -> Version {
        var version = version
        switch version.kind {
        case .snapshot(let snapshot, let pages):
            guard
                let saved = try? await Persistence.store.readSnapshot(snapshot)
            else {
                version.isDamaged = true
                break
            }
            let shown = saved.annotations.moved(fromPages: pages, toPages: now)
            version.annotations = shown
            version.leftOut = saved.annotations.count - shown.count
        case .pageOrder(let order, let earlier):
            guard
                let data = order.pdfURL.flatMap({
                    try? Data(contentsOf: $0, options: .alwaysMapped)
                })
            else {
                version.isDamaged = true
                break
            }
            version.pdf = data
            version.annotations = session.annotations.restoringPages(
                order.identity.pageIDs, from: now, earlier: earlier)
        case .original:
            break
        }
        return version
    }

    func isSameAsNow(_ version: Version) -> Bool {
        version.pageOrder == nil && version.annotations == session.annotations
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
