import Foundation

/// An immutable snapshot file, named `<UTC time>-r<revision>.json`.
public struct SnapshotInfo: Identifiable, Hashable, Sendable {
    public let url: URL
    public let date: Date
    public let revision: Int
    public var id: URL { url }

    public init(url: URL, date: Date, revision: Int) {
        self.url = url
        self.date = date
        self.revision = revision
    }

    /// Parses a snapshot file name. Returns nil for anything else, such as
    /// temp files.
    init?(url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json",
            let dash = name.lastIndex(of: "-"),
            name[name.index(after: dash)...].hasPrefix("r"),
            let revision = Int(name[name.index(dash, offsetBy: 2)...]),
            let date = Timestamp.parse(String(name[..<dash]), compact: true)
        else { return nil }
        self.init(url: url, date: date, revision: revision)
    }

    static func fileName(date: Date, revision: Int) -> String {
        "\(Timestamp.string(date, compact: true))-r\(revision).json"
    }
}

/// Which snapshots to keep, on the standard schedule:
/// - the first version: the oldest snapshot is never deleted
/// - everything from the last 24 hours
/// - the newest per hour for snapshots up to 7 days old
/// - the newest per day for snapshots up to 30 days old
/// - nothing else older
///
/// Besides the first version, at least `minimumKept` snapshots always remain,
/// however old: if the rules above would leave fewer, the newest of the rest
/// are kept too. So a document with five or more snapshots always keeps at
/// least five, the newest is never deleted, and a document picked up again
/// after a long break still has its last few versions and its first. Hour
/// and day buckets are in UTC, so the result doesn't depend on time zone or
/// daylight saving.
///
/// It runs after each save, for the document that was saved: the snapshots of
/// all its page orders together, as one history. A document that's no longer
/// edited keeps its snapshots as they are.
public enum RetentionPolicy {
    public struct Schedule: Sendable {
        public var keepAllFor: TimeInterval
        public var keepHourlyFor: TimeInterval
        public var keepDailyFor: TimeInterval
        /// Kept besides the first version.
        public var minimumKept: Int

        public static let standard = Schedule(
            keepAllFor: day, keepHourlyFor: 7 * day, keepDailyFor: 30 * day,
            minimumKept: 4)

        /// For copies of PDFs over 100 MB: the same steps, each much shorter.
        public static let large = Schedule(
            keepAllFor: hour, keepHourlyFor: day, keepDailyFor: 7 * day,
            minimumKept: 1)
    }

    private static let hour: TimeInterval = 3600
    private static let day = 24 * hour

    /// With `keepingFirst` false, the oldest is thinned out like the rest.
    public static func snapshotsToDelete(
        _ snapshots: [SnapshotInfo], now: Date,
        schedule: Schedule = .standard, keepingFirst: Bool = true
    ) -> [SnapshotInfo] {
        let sorted = snapshots.sorted {
            ($0.date, $0.revision) > ($1.date, $1.revision)
        }
        // The last of these is the first version.
        let newestFirst = keepingFirst ? sorted.dropLast() : sorted[...]
        var keptHours = Set<Int>()
        var keptDays = Set<Int>()
        var toDelete: [SnapshotInfo] = []

        for snapshot in newestFirst {
            let age = now.timeIntervalSince(snapshot.date)
            let time = snapshot.date.timeIntervalSince1970
            let keep: Bool
            if age <= schedule.keepAllFor {
                // everything recent, and anything dated in the future
                keep = true
            } else if age <= schedule.keepHourlyFor {
                keep =
                    keptHours.insert(Int((time / hour).rounded(.down)))
                    .inserted
            } else if age <= schedule.keepDailyFor {
                keep =
                    keptDays.insert(Int((time / day).rounded(.down))).inserted
            } else {
                keep = false
            }
            if !keep { toDelete.append(snapshot) }
        }
        // `toDelete` is newest first, so this spares the newest of the rest.
        let shortfall =
            schedule.minimumKept - (newestFirst.count - toDelete.count)
        return shortfall > 0 ? Array(toDelete.dropFirst(shortfall)) : toDelete
    }
}
