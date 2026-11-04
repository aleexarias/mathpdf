import Foundation
import Testing

@testable import MathPDFCore

@Suite struct RetentionTests {
    let hour: TimeInterval = 3600
    var day: TimeInterval { 24 * hour }
    /// On an hour boundary, so bucket edges in the tests are easy to reason
    /// about.
    let now = Timestamp.parse("2026-11-03T12:00:00.000Z")!

    private func snapshot(ageSeconds: TimeInterval, revision: Int = 0)
        -> SnapshotInfo
    {
        let date = now - ageSeconds
        let name = SnapshotInfo.fileName(date: date, revision: revision)
        return SnapshotInfo(
            url: URL(fileURLWithPath: "/snapshots/\(name)"),
            date: date, revision: revision)
    }

    /// The PDF's first saved version, older than anything else in a test, so
    /// the rules below are tested on the rest. It's always kept (see
    /// `alwaysKeepsTheFirstVersion`).
    private var firstVersion: SnapshotInfo { snapshot(ageSeconds: 2000 * day) }

    /// For copies of big PDFs: everything for an hour, one per hour for a
    /// day, one per day for a week, at least the newest, and the oldest is
    /// thinned like the rest.
    @Test func theLargeScheduleIsShorter() {
        let recent = snapshot(ageSeconds: 0.5 * hour)
        // 09:45 and 09:15
        let sameHour = [
            snapshot(ageSeconds: 2.25 * hour),
            snapshot(ageSeconds: 2.75 * hour),
        ]
        let sameDay = [
            snapshot(ageSeconds: 2 * day),
            snapshot(ageSeconds: 2 * day + hour),
        ]
        let old = snapshot(ageSeconds: 8 * day)
        let deleted = RetentionPolicy.snapshotsToDelete(
            [recent, old] + sameHour + sameDay, now: now, schedule: .large,
            keepingFirst: false)
        #expect(Set(deleted) == [sameHour[1], sameDay[1], old])
        let alone = RetentionPolicy.snapshotsToDelete(
            [old], now: now, schedule: .large, keepingFirst: false)
        #expect(alone.isEmpty)
    }

    @Test func keepsEverythingFromTheLast24Hours() {
        let snapshots = stride(from: 0, through: day, by: 97).map {
            snapshot(ageSeconds: $0)
        }
        let deleted = RetentionPolicy.snapshotsToDelete(
            snapshots + [firstVersion], now: now)
        #expect(deleted.isEmpty)
    }

    @Test func keepsTheNewestPerHourUpTo7Days() {
        var kept: [SnapshotInfo] = []
        var doomed: [SnapshotInfo] = []
        for hoursAgo in 25...(7 * 24) {
            // Three snapshots inside the same UTC hour (at :05, :20 and :40);
            // only the newest survives.
            let hourStart = Double(hoursAgo) * hour
            kept.append(snapshot(ageSeconds: hourStart - 40 * 60))
            doomed.append(snapshot(ageSeconds: hourStart - 20 * 60))
            doomed.append(snapshot(ageSeconds: hourStart - 5 * 60))
        }
        let deleted = RetentionPolicy.snapshotsToDelete(
            kept + doomed + [snapshot(ageSeconds: 60), firstVersion], now: now)
        #expect(Set(deleted) == Set(doomed))
    }

    @Test func keepsTheNewestPerDayUpTo30Days() {
        var kept: [SnapshotInfo] = []
        var doomed: [SnapshotInfo] = []
        for daysAgo in 8...30 {
            // `now` is 12:00 UTC, so these all fall on the same UTC day.
            let noon = Double(daysAgo) * day
            kept.append(snapshot(ageSeconds: noon - 3 * hour))
            doomed.append(snapshot(ageSeconds: noon))
            doomed.append(snapshot(ageSeconds: noon + 5 * hour))
        }
        let deleted = RetentionPolicy.snapshotsToDelete(
            kept + doomed + [snapshot(ageSeconds: 60), firstVersion], now: now)
        #expect(Set(deleted) == Set(doomed))
    }

    @Test func deletesEverythingOlderThan30Days() {
        let old = [30.5, 31, 45, 91, 365, 1000].map {
            snapshot(ageSeconds: $0 * day)
        }
        // enough to meet the minimum
        let recent = (1...4).map { snapshot(ageSeconds: Double($0) * hour) }
        #expect(
            Set(
                RetentionPolicy.snapshotsToDelete(
                    old + recent + [firstVersion], now: now)) == Set(old))
    }

    @Test func alwaysKeepsTheFirstVersion() {
        // The oldest is kept however old, alongside everything the other rules
        // keep.
        let first = snapshot(ageSeconds: 5000 * day, revision: 1)
        let old = [31.0, 45, 91, 365].map { snapshot(ageSeconds: $0 * day) }
        let recent = (1...6).map { snapshot(ageSeconds: Double($0) * hour) }
        let deleted = RetentionPolicy.snapshotsToDelete(
            recent + old + [first], now: now)
        #expect(Set(deleted) == Set(old))
        #expect(!deleted.contains(first))
    }

    @Test func alwaysKeepsAtLeastFiveCopies() {
        // Picked up again after a long break: one new save, everything else
        // past 30 days.
        let recent = snapshot(ageSeconds: 60)
        let old = (0..<10).map {
            snapshot(ageSeconds: (60 + Double($0)) * day)
        }  // newest first
        let deleted = RetentionPolicy.snapshotsToDelete(
            [recent] + old, now: now)
        // The new save, the three newest old copies and the first version
        // stay.
        #expect(Set(deleted) == Set(old.dropFirst(3).dropLast()))

        // Everything old: the four newest and the first version stay.
        #expect(
            Set(RetentionPolicy.snapshotsToDelete(old, now: now))
                == Set(old.dropFirst(4).dropLast()))

        // Five or fewer: nothing is deleted, however old.
        #expect(
            RetentionPolicy.snapshotsToDelete(Array(old.prefix(5)), now: now)
                .isEmpty)
        #expect(
            RetentionPolicy.snapshotsToDelete(Array(old.prefix(2)), now: now)
                .isEmpty)
    }

    @Test(arguments: [0.0, 2, 30, 91, 200, 5000])
    func neverDeletesTheNewestSnapshot(ageInDays: Double) {
        let newest = snapshot(ageSeconds: ageInDays * day, revision: 9)
        let older = (1...50).map {
            snapshot(
                ageSeconds: ageInDays * day + Double($0) * 7 * hour,
                revision: 9 - $0)
        }
        let deleted = RetentionPolicy.snapshotsToDelete(
            [newest] + older, now: now)
        #expect(!deleted.contains(newest))
        #expect(RetentionPolicy.snapshotsToDelete([newest], now: now).isEmpty)
    }

    @Test func sameTimestampKeepsTheHigherRevision() {
        // Three recent copies, plus two old ones that tie on time: the fourth
        // copy kept to meet the minimum is the one with the higher revision.
        let recent = (1...3).map {
            snapshot(ageSeconds: Double($0) * hour, revision: 10 + $0)
        }
        let a = snapshot(ageSeconds: 200 * day, revision: 4)
        let b = snapshot(ageSeconds: 200 * day, revision: 5)
        #expect(
            RetentionPolicy.snapshotsToDelete(
                recent + [a, b, firstVersion], now: now) == [a])

        // Tied for the oldest, the lower revision is the first version.
        #expect(RetentionPolicy.snapshotsToDelete([a, b], now: now).isEmpty)
        let older = (1...5).map {
            snapshot(
                ageSeconds: 100 * day - Double($0) * hour, revision: 20 + $0)
        }
        #expect(
            !RetentionPolicy.snapshotsToDelete(older + [b, a], now: now)
                .contains(a))
    }

    @Test func snapshotFileNamesRoundTrip() throws {
        let date = Timestamp.parse("2026-11-03T11:44:02.317Z")!
        let name = SnapshotInfo.fileName(date: date, revision: 42)
        #expect(name == "20261103T114402.317Z-r42.json")
        let parsed = try #require(
            SnapshotInfo(url: URL(fileURLWithPath: "/x/\(name)")))
        #expect(parsed.date == date)
        #expect(parsed.revision == 42)
        #expect(
            SnapshotInfo(
                url: URL(
                    fileURLWithPath: "/x/.\(name)\(AtomicFile.tempMarker)ABC"))
                == nil)
        #expect(SnapshotInfo(url: URL(fileURLWithPath: "/x/notes.txt")) == nil)
    }
}

/// Retention as it happens on disk: a fake clock drives months of saves
/// through the store.
@Suite final class RetentionOnDiskTests: Sendable {
    let root = makeTemporaryRoot()

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func monthsOfSavesArePrunedByThePolicy() async throws {
        let clock = FakeClock()
        let store = AnnotationStore(rootURL: root, now: clock.now)
        var set = makeSet(revision: 0)
        // Every 5 hours for 120 days, then a burst of edits a few seconds
        // apart.
        for _ in 0..<(120 * 24 / 5) {
            set.revision += 1
            try await store.save(set)
            clock.advance(by: 5 * 3600)
        }
        for _ in 0..<20 {
            set.revision += 1
            set.annotations.append(Samples.pointNote(index: set.revision))
            try await store.save(set)
            clock.advance(by: 2)
        }

        let now = clock.now()
        let snapshots = await store.snapshots(documentHash: testHash)
        let ages = snapshots.map { now.timeIntervalSince($0.date) / 86400 }
        #expect(snapshots.first?.revision == set.revision)
        // the first save, 120 days ago, is still there
        #expect(snapshots.last?.revision == 1)
        #expect(ages.dropLast().allSatisfy { $0 <= 30 })
        #expect(
            snapshots.filter { now.timeIntervalSince($0.date) < 60 }.count
                == 20)

        // From 7 to 30 days, at most one per UTC day.
        let dailyDays = snapshots.filter {
            now.timeIntervalSince($0.date) > 7 * 86400
        }
        .map { Int($0.date.timeIntervalSince1970 / 86400) }
        #expect(Set(dailyDays).count == dailyDays.count)
        #expect(RetentionPolicy.snapshotsToDelete(snapshots, now: now).isEmpty)
    }
}
