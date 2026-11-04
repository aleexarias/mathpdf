import Foundation
import Testing

@testable import MathPDFCore

/// A crash is simulated by a hook that throws after the temp file is fully
/// written and flushed but before it replaces the store, which leaves the disk
/// exactly as a killed process would. A new `AnnotationStore` then stands in
/// for the relaunched app.
@Suite final class CrashSafetyTests: Sendable {
    let root = makeTemporaryRoot()

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func crashBetweenTempWriteAndReplaceKeepsTheOldState() async throws {
        let store = AnnotationStore(rootURL: root)
        let before = makeSet(
            revision: 1, annotations: Samples.underlineLines())
        try await store.save(before)

        await store.setBeforeStoreReplace { throw SimulatedCrash() }
        var after = before
        after.revision = 2
        after.annotations.append(Samples.latex())
        await #expect(throws: SimulatedCrash.self) {
            try await store.save(after)
        }
        #expect(tempFiles(in: store.folderURL(testHash)).count == 1)

        let relaunched = AnnotationStore(rootURL: root)
        let result = await relaunched.load(documentHash: testHash)
        guard case .loaded(let loaded, _) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(loaded.revision == 1)
        #expect(loaded.annotations == before.annotations)
        #expect(tempFiles(in: store.folderURL(testHash)).isEmpty)
    }

    @Test func crashHalfwayThroughTheTempFileKeepsTheOldState() async throws {
        let store = AnnotationStore(rootURL: root)
        let before = makeSet(revision: 1, annotations: [Samples.highlight()])
        try await store.save(before)

        // A process killed mid-write leaves a truncated temp file next to the
        // store.
        let newBytes = try StoreFile.encode(
            makeSet(revision: 2, annotations: Samples.everyKind()))
        let torn = store.folderURL(testHash).appending(
            path: ".store.json\(AtomicFile.tempMarker)\(UUID().uuidString)")
        try newBytes.prefix(newBytes.count / 2).write(to: torn)

        let result = await AnnotationStore(rootURL: root).load(
            documentHash: testHash)
        #expect(result.set?.revision == 1)
        #expect(result.set?.annotations == before.annotations)
        #expect(!FileManager.default.fileExists(atPath: torn.path))
    }

    @Test func crashDuringTheVeryFirstSaveStartsFresh() async throws {
        let store = AnnotationStore(rootURL: root)
        await store.setBeforeStoreReplace { throw SimulatedCrash() }
        await #expect(throws: SimulatedCrash.self) {
            try await store.save(makeSet(revision: 1))
        }

        // Nothing was ever committed, so empty is the correct "old" state.
        let result = await AnnotationStore(rootURL: root).load(
            documentHash: testHash)
        guard case .fresh = result else {
            Issue.record("Expected .fresh, got \(result)")
            return
        }
    }

    /// Crashes at random points across many saves. After each one, a relaunch
    /// must load exactly the last state whose save completed.
    @Test func repeatedCrashesNeverLoseCommittedState() async throws {
        let store = AnnotationStore(rootURL: root)
        var committed: AnnotationSet?
        var set = makeSet(revision: 0)

        for step in 1...40 {
            set.revision = step
            set.annotations.append(Samples.pointNote(index: step))
            let crash = Bool.random()
            await store.setBeforeStoreReplace(
                crash ? { @Sendable in throw SimulatedCrash() } : nil)
            do {
                try await store.save(set)
                committed = set
            } catch is SimulatedCrash {
                #expect(crash)
            }

            let relaunched = AnnotationStore(rootURL: root)
            let loaded = await relaunched.load(documentHash: testHash).set
            #expect(loaded?.revision == committed?.revision)
            #expect(loaded?.annotations == committed?.annotations)
        }
    }
}
