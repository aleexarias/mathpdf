import Foundation
import Testing

@testable import MathPDFCore

extension DiskHeavyTests {
    @Suite final class ConcurrencyTests: Sendable {
        let root = makeTemporaryRoot()

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Saves arriving out of order (as unstructured tasks can) must never
        /// let an older state overwrite a newer one.
        @Test func concurrentSavesInRandomOrderEndOnTheNewestState()
            async throws
        {
            let store = AnnotationStore(rootURL: root)
            let states = (1...150).map { revision in
                makeSet(
                    revision: revision,
                    annotations: (1...revision).map {
                        Samples.pointNote(index: $0)
                    })
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for state in states.shuffled() {
                    group.addTask { try await store.save(state) }
                }
                try await group.waitForAll()
            }

            let loaded = try #require(
                await AnnotationStore(rootURL: root).load(
                    documentHash: testHash
                )
                .set)
            #expect(loaded.revision == 150)
            #expect(loaded.annotations == states.last?.annotations)

            // Snapshots were only ever written in increasing revision order.
            let revisions = await store.snapshots(documentHash: testHash).map(
                \.revision)
            #expect(revisions == revisions.sorted(by: >))
        }

        @MainActor @Test func rapidEditsThroughTheAutosaverLoseNothing()
            async throws
        {
            let store = AnnotationStore(rootURL: root)
            let autosaver = Autosaver(store: store, delay: .milliseconds(2))
            var set = makeSet(revision: 0)

            for edit in 1...300 {
                set.revision += 1
                set.annotations.append(Samples.pointNote(index: edit))
                if edit.isMultiple(of: 3) {
                    set.annotations[0].bounds.origin.x += 1
                }  // edits, not just appends
                autosaver.changed(set)
                if edit.isMultiple(of: 10) {
                    try await Task.sleep(for: .milliseconds(3))
                }  // let scheduled saves fire mid-burst
                if edit.isMultiple(of: 75) { await autosaver.flush() }
            }
            await autosaver.flush()

            #expect(!autosaver.hasUnsavedChanges)
            #expect(autosaver.lastError == nil)
            #expect(autosaver.lastSavedRevision == 300)
            let loaded = try #require(
                await AnnotationStore(rootURL: root).load(
                    documentHash: testHash
                )
                .set)
            #expect(loaded.revision == 300)
            #expect(loaded.annotations == set.annotations)
        }

        /// Constant editing doesn't keep postponing the save: one is written
        /// per interval, with everything changed up to then, and the rest
        /// waits for the next one (or a flush).
        @MainActor @Test func constantEditingSavesOncePerInterval()
            async throws
        {
            let store = AnnotationStore(rootURL: root)
            let interval = Duration.milliseconds(100)
            let autosaver = Autosaver(store: store, delay: interval)
            var set = makeSet(revision: 0)
            let clock = ContinuousClock(), start = clock.now
            // an edit every 10 ms or so
            while clock.now - start < .seconds(1) {
                set.revision += 1
                set.annotations.append(Samples.pointNote(index: set.revision))
                autosaver.changed(set)
                try await Task.sleep(for: .milliseconds(10))
            }
            let elapsed = clock.now - start
            let saves = await store.snapshots(documentHash: testHash).count
            // Never more than one per interval, but saves do happen while
            // editing goes on (a debounce would write none until it stopped).
            // Loose bounds: tests run in parallel.
            #expect(
                saves <= Int(elapsed / interval) + 1,
                "\(saves) saves in \(elapsed)")
            #expect(saves >= 3, "\(saves) saves in \(elapsed)")
            #expect(
                saves < set.revision / 3,
                "\(saves) saves for \(set.revision) edits")
            let lastSaved = try #require(autosaver.lastSavedRevision)
            // each save wrote everything changed up to then
            #expect(lastSaved > set.revision / 2)

            await autosaver.flush()
            #expect(autosaver.lastSavedRevision == set.revision)
            #expect(!autosaver.hasUnsavedChanges)
        }

        @MainActor @Test func flushWritesAPendingChangeImmediately()
            async throws
        {
            let store = AnnotationStore(rootURL: root)
            let autosaver = Autosaver(store: store, delay: .seconds(3600))
            let set = makeSet(revision: 1, annotations: [Samples.latex()])
            autosaver.changed(set)
            #expect(autosaver.hasUnsavedChanges)

            await autosaver.flush()
            #expect(!autosaver.hasUnsavedChanges)
            let reopened = AnnotationStore(rootURL: root)
            let saved = await reopened.load(documentHash: testHash).set
            #expect(try #require(saved).annotations == set.annotations)
        }

        /// A save that loses to a higher revision used to vanish, with the
        /// window showing it as saved.
        @MainActor @Test func aSaveBehindTheStoreIsntDropped() async throws {
            let store = AnnotationStore(rootURL: root)
            let earlier = makeSet(revision: 5, annotations: [Samples.latex()])
            try await store.save(earlier)

            let autosaver = Autosaver(store: store, delay: .seconds(3600))
            let behind = makeSet(
                revision: 3, annotations: [Samples.highlight()])
            autosaver.changed(behind)
            await autosaver.flush()
            #expect(!autosaver.hasUnsavedChanges)
            #expect(autosaver.lastSavedRevision == 6)

            let reopened = AnnotationStore(rootURL: root)
            let saved = await reopened.load(documentHash: testHash).set
            #expect(try #require(saved).annotations == behind.annotations)
            #expect(saved?.revision == 6)
            let history = await reopened.snapshots(documentHash: testHash)
            #expect(history.map(\.revision) == [6, 5])
        }

        @MainActor @Test func aFailedSaveIsTriedAgainByItself() async throws {
            let store = AnnotationStore(rootURL: root)
            await store.setBeforeStoreReplace { throw SimulatedCrash() }
            let autosaver = Autosaver(store: store, delay: .milliseconds(20))
            let set = makeSet(revision: 1, annotations: [Samples.latex()])
            autosaver.changed(set)
            for _ in 0..<500 where autosaver.lastError == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(autosaver.lastError != nil)
            #expect(autosaver.hasUnsavedChanges)

            await store.setBeforeStoreReplace(nil)
            for _ in 0..<500 where autosaver.lastError != nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(autosaver.lastError == nil)
            #expect(!autosaver.hasUnsavedChanges)
            let saved = await store.load(documentHash: testHash).set
            #expect(saved?.annotations == set.annotations)
        }

        @MainActor @Test func failedSaveIsKeptAndRetried() async throws {
            let store = AnnotationStore(rootURL: root)
            // Make the store unreadable so saving is blocked.
            try await store.save(makeSet(revision: 1))
            try Data("garbage".utf8).write(to: store.storeURL(testHash))
            for snapshot in await store.snapshots(documentHash: testHash) {
                try FileManager.default.removeItem(at: snapshot.url)
            }
            let relaunched = AnnotationStore(rootURL: root)
            _ = await relaunched.load(documentHash: testHash)

            let autosaver = Autosaver(store: relaunched, delay: .seconds(3600))
            let set = makeSet(revision: 2, annotations: [Samples.highlight()])
            autosaver.changed(set)
            await autosaver.flush()
            #expect(autosaver.lastError != nil)
            #expect(autosaver.hasUnsavedChanges)

            await relaunched.allowFreshStart(documentHash: testHash)
            await autosaver.flush()
            #expect(autosaver.lastError == nil)
            #expect(!autosaver.hasUnsavedChanges)
            let reopened = AnnotationStore(rootURL: root)
            let saved = await reopened.load(documentHash: testHash).set
            #expect(try #require(saved).annotations == set.annotations)
        }
    }
}
