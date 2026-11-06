import Foundation
import Testing

@testable import MathPDFCore

@Suite final class RecoveryTests: Sendable {
    let root = makeTemporaryRoot()
    let clock = FakeClock()

    deinit { try? FileManager.default.removeItem(at: root) }

    enum Damage: String, CaseIterable, Sendable {
        case truncated, garbage, empty, checksumMismatch, wrongEnvelope

        func apply(to url: URL) throws {
            let data = try Data(contentsOf: url)
            switch self {
            case .truncated: try data.prefix(data.count / 3).write(to: url)
            case .garbage:
                try Data((0..<512).map { _ in UInt8.random(in: 0...255) })
                    .write(to: url)
            case .empty: try Data().write(to: url)
            case .checksumMismatch:
                // Still valid JSON, but the payload no longer matches its
                // checksum.
                let text = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(
                        of: "\"pageCount\" : 12", with: "\"pageCount\" : 13")
                try Data(text.utf8).write(to: url)
            case .wrongEnvelope:
                try Data(#"{"hello":"world"}"#.utf8).write(to: url)
            }
        }
    }

    /// Saves revisions 1 and 2, a minute apart, and returns revision 2.
    private func saveTwoRevisions(_ store: AnnotationStore) async throws
        -> AnnotationSet
    {
        try await store.save(
            makeSet(revision: 1, annotations: [Samples.highlight()]))
        clock.advance(by: 60)
        let latest = makeSet(
            revision: 2, annotations: [Samples.highlight(), Samples.latex()])
        try await store.save(latest)
        return latest
    }

    @Test(arguments: Damage.allCases)
    func damagedStoreRecoversFromTheLatestSnapshot(damage: Damage) async throws
    {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        let latest = try await saveTwoRevisions(store)
        let storeURL = store.storeURL(testHash)
        try damage.apply(to: storeURL)
        let damagedBytes = try Data(contentsOf: storeURL)

        let relaunched = AnnotationStore(rootURL: root, now: clock.now)
        let result = await relaunched.load(documentHash: testHash)
        guard case .recovered(let set, let snapshot, let problem) = result
        else {
            Issue.record("Expected .recovered, got \(result)")
            return
        }
        #expect(set.revision == 2)
        #expect(set.annotations == latest.annotations)
        #expect(snapshot.revision == 2)
        #expect(problem.contains("couldn't be read"))

        // The damaged file is kept, not deleted.
        let folder = store.folderURL(testHash)
        let files = try FileManager.default.contentsOfDirectory(
            atPath: folder.path)
        let corrupt = files.filter { $0.hasPrefix("store.corrupt-") }
        #expect(corrupt.count == 1)
        #expect(
            try Data(contentsOf: folder.appending(path: corrupt[0]))
                == damagedBytes)

        // The current file is valid again, so the next launch loads normally.
        let nextLaunch = AnnotationStore(rootURL: root)
        let next = await nextLaunch.load(documentHash: testHash)
        guard case .loaded(let reloaded, _) = next else {
            Issue.record("Expected a normal load after recovery")
            return
        }
        #expect(reloaded.revision == 2)
    }

    @Test func missingStoreRecoversFromTheLatestSnapshot() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        let latest = try await saveTwoRevisions(store)
        try FileManager.default.removeItem(at: store.storeURL(testHash))

        let result = await AnnotationStore(rootURL: root).load(
            documentHash: testHash)
        guard case .recovered(let set, _, let problem) = result else {
            Issue.record("Expected .recovered, got \(result)")
            return
        }
        #expect(set.annotations == latest.annotations)
        #expect(problem.contains("missing"))
    }

    @Test func damagedLatestSnapshotFallsBackToTheOneBefore() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        try Damage.garbage.apply(to: store.storeURL(testHash))
        let newest = try #require(
            await store.snapshots(documentHash: testHash).first)
        try Damage.truncated.apply(to: newest.url)

        let result = await AnnotationStore(rootURL: root).load(
            documentHash: testHash)
        guard case .recovered(let set, let snapshot, _) = result else {
            Issue.record("Expected .recovered, got \(result)")
            return
        }
        #expect(set.revision == 1)
        #expect(snapshot.revision == 1)
    }

    @Test func nothingReadableBlocksSavingInsteadOfStartingEmpty() async throws
    {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        try Damage.garbage.apply(to: store.storeURL(testHash))
        for snapshot in await store.snapshots(documentHash: testHash) {
            try Damage.garbage.apply(to: snapshot.url)
        }
        let snapshotBytes = try await store.snapshots(documentHash: testHash)
            .map { try Data(contentsOf: $0.url) }

        let relaunched = AnnotationStore(rootURL: root, now: clock.now)
        guard
            case .blocked(.noValidData) = await relaunched.load(
                documentHash: testHash)
        else {
            Issue.record("Expected .blocked(.noValidData)")
            return
        }
        await #expect(throws: AnnotationStoreError.self) {
            try await relaunched.save(makeSet(revision: 3))
        }
        #expect(
            try await relaunched.snapshots(documentHash: testHash).map {
                try Data(contentsOf: $0.url)
            } == snapshotBytes)

        // Only an explicit decision by the user unblocks it, and the old files
        // stay put.
        await relaunched.allowFreshStart(documentHash: testHash)
        try await relaunched.save(
            makeSet(revision: 1, annotations: [Samples.pointNote()]))
        #expect(await relaunched.snapshots(documentHash: testHash).count == 3)
    }

    @Test func fileFromANewerAppVersionIsNeverOverwritten() async throws {
        let store = AnnotationStore(rootURL: root)
        try await store.save(makeSet(revision: 1))
        let storeURL = store.storeURL(testHash)
        let json =
            #"{"schemaVersion":99,"sha256":"0000","#
            + #""payload":{"futureField":true}}"#
        let newer = Data(json.utf8)
        try newer.write(to: storeURL)

        let relaunched = AnnotationStore(rootURL: root)
        guard
            case .blocked(.newerSchema(99)) = await relaunched.load(
                documentHash: testHash)
        else {
            Issue.record("Expected .blocked(.newerSchema(99))")
            return
        }
        await #expect(throws: AnnotationStoreError.self) {
            try await relaunched.save(makeSet(revision: 50))
        }
        // only lifts .noValidData
        await relaunched.allowFreshStart(documentHash: testHash)
        await #expect(throws: AnnotationStoreError.self) {
            try await relaunched.save(makeSet(revision: 50))
        }

        // Same for an app instance that saves without loading first.
        await #expect(throws: AnnotationStoreError.self) {
            try await AnnotationStore(rootURL: root).save(
                makeSet(revision: 50))
        }
        #expect(try Data(contentsOf: storeURL) == newer)
    }

    @Test func unknownPDFStartsFresh() async {
        guard
            case .fresh = await AnnotationStore(rootURL: root).load(
                documentHash: testHash)
        else {
            Issue.record("Expected .fresh")
            return
        }
    }

    // MARK: What can be relinked from

    private let otherHash = String(repeating: "ef", count: 32)

    private func hashes(_ sets: [AnnotationStore.StoredSetSummary]) -> [String]
    {
        sets.map(\.documentHash)
    }

    @Test func aSavedSetIsOfferedWithItsDetails() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        let offered = await store.storedSets(except: otherHash)
        #expect(hashes(offered) == [testHash])
        #expect(offered.first?.annotationCount == 2)
        #expect(offered.first?.fileNameHint == "paper.pdf")
        #expect(offered.first?.pageCount == 12)
    }

    @Test func thePDFItselfIsntOffered() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        #expect(await store.storedSets(except: testHash).isEmpty)
    }

    @Test func aSetWithNothingToCopyIsntOffered() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        clock.advance(by: 60)
        try await store.save(
            makeSet(hash: otherHash, revision: 1, annotations: []))
        #expect(hashes(await store.storedSets(except: "x")) == [testHash])
    }

    @Test func theNewestSetComesFirst() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        try await store.save(
            makeSet(revision: 1, annotations: [Samples.highlight()]))
        clock.advance(by: 60)
        try await store.save(
            makeSet(
                hash: otherHash, revision: 1,
                annotations: [Samples.highlight()]))
        #expect(
            hashes(await store.storedSets(except: "x"))
                == [otherHash, testHash])
    }

    /// The pages of a document that have since moved aren't another set: only
    /// how it is now is offered, and not at all when copying onto itself.
    @Test func aDocumentIsOfferedOnce() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        let identity = PageIdentity(pageCount: 12)
        try await store.save(
            makeSet(revision: 1, annotations: [Samples.highlight()]))
        try await store.savePageIdentity(identity, documentHash: testHash)
        clock.advance(by: 60)
        try await store.save(
            makeSet(
                hash: otherHash, revision: 2,
                annotations: [Samples.highlight()]))
        try await store.savePageIdentity(identity, documentHash: otherHash)

        #expect(hashes(await store.storedSets(except: "x")) == [otherHash])
        #expect(
            await store.storedSets(
                except: "x", document: identity.documentID
            ).isEmpty)
    }

    /// A document that has lost its annotations isn't offered through a page
    /// order that still had them.
    @Test func aDocumentCountsAsItIsNow() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        let identity = PageIdentity(pageCount: 12)
        try await store.save(
            makeSet(revision: 1, annotations: [Samples.highlight()]))
        try await store.savePageIdentity(identity, documentHash: testHash)
        clock.advance(by: 60)
        try await store.save(
            makeSet(hash: otherHash, revision: 2, annotations: []))
        try await store.savePageIdentity(identity, documentHash: otherHash)
        #expect(await store.storedSets(except: "x").isEmpty)
    }

    @Test func aDamagedSetIsOfferedFromItsSnapshot() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        let saved = try await saveTwoRevisions(store)
        try Data("garbage".utf8).write(to: store.storeURL(testHash))
        let offered = await AnnotationStore(rootURL: root).storedSets(
            except: "x")
        #expect(offered.first?.annotationCount == saved.annotations.count)
    }

    @Test func aSetThatCantBeReadIsntOffered() async throws {
        let store = AnnotationStore(rootURL: root, now: clock.now)
        _ = try await saveTwoRevisions(store)
        try FileManager.default.removeItem(at: store.snapshotsURL(testHash))
        try Data("garbage".utf8).write(to: store.storeURL(testHash))
        #expect(
            await AnnotationStore(rootURL: root).storedSets(except: "x")
                .isEmpty)
    }
}
