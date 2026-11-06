import Foundation
import Testing

@testable import MathPDFCore

@Suite final class RoundTripTests: Sendable {
    let root = makeTemporaryRoot()

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func everyAnnotationKindSurvivesSaveAndLoad() async throws {
        let clock = FakeClock()
        var original = makeSet(revision: 1, annotations: Samples.everyKind())
        original.relinkedFrom = String(repeating: "cd", count: 32)
        try await AnnotationStore(rootURL: root, now: clock.now).save(original)

        let result = await AnnotationStore(rootURL: root).load(
            documentHash: testHash)
        guard case .loaded(let loaded, let migratedFrom) = result else {
            Issue.record("Expected .loaded, got \(result)")
            return
        }
        #expect(migratedFrom == nil)
        #expect(loaded.annotations == original.annotations)
        #expect(loaded.savedAt == clock.now())
        original.savedAt = clock.now()
        #expect(loaded == original)
    }

    @Test(arguments: Samples.trickyLaTeX)
    func latexSourceIsStoredVerbatim(source: String) throws {
        let set = makeSet(revision: 1, annotations: [Samples.latex(source)])
        let decoded = try StoreFile.decode(StoreFile.encode(set))
        guard
            case .latex(let roundTripped, let fontSize, _) = decoded.set
                .annotations.first?.kind
        else {
            Issue.record("LaTeX annotation lost")
            return
        }
        #expect(roundTripped == source)
        #expect(
            Array(roundTripped.unicodeScalars) == Array(source.unicodeScalars))
        #expect(fontSize == 15.5)
    }

    @Test func snapshotMatchesTheStoreByteForByte() async throws {
        let store = AnnotationStore(rootURL: root)
        let set = makeSet(revision: 1, annotations: Samples.everyKind())
        try await store.save(set)

        let snapshots = await store.snapshots(documentHash: testHash)
        try #require(snapshots.count == 1)
        #expect(snapshots[0].revision == 1)
        #expect(
            try Data(contentsOf: snapshots[0].url)
                == Data(contentsOf: store.storeURL(testHash)))
        #expect(
            try await store.readSnapshot(snapshots[0]).annotations
                == set.annotations)
    }

    @Test func timestampsRoundTripExactly() {
        for _ in 0..<1000 {
            let date = Date(
                timeIntervalSince1970: .random(in: 0...4_102_444_800))
            let normalized = Timestamp.normalized(date)
            #expect(Timestamp.parse(Timestamp.string(date)) == normalized)
            #expect(
                Timestamp.parse(
                    Timestamp.string(date, compact: true), compact: true)
                    == normalized)
        }
        #expect(
            Timestamp.string(Timestamp.parse("2026-11-03T11:44:02.317Z")!)
                == "2026-11-03T11:44:02.317Z")
        #expect(
            Timestamp.string(
                Timestamp.parse("2026-11-03T11:44:02.007Z")!, compact: true)
                == "20261103T114402.007Z")
    }

    @Test func checksumDetectsAnyChangeToThePayload() throws {
        let data = try StoreFile.encode(
            makeSet(revision: 1, annotations: [Samples.highlight()]))
        var tampered = data
        let index =
            try #require(data.range(of: Data("\"pageCount\" : 12".utf8)))
            .upperBound - 1
        tampered[index] = UInt8(ascii: "3")
        #expect(throws: StoreFileError.checksumMismatch) {
            try StoreFile.decode(tampered)
        }
    }

    /// Bigger than the pieces it's read in.
    @Test(arguments: [0, 1, 1 << 20, (1 << 20) + 1, 3 << 20])
    func aFileHashesLikeItsBytes(_ size: Int) throws {
        let url = makeTemporaryRoot().appending(path: "file")
        let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try bytes.write(to: url)
        #expect(try sha256Hex(ofFileAt: url) == sha256Hex(bytes))
    }

    @Test func aMissingFileCantBeHashed() {
        let url = makeTemporaryRoot().appending(path: "not there")
        #expect(throws: (any Error).self) { try sha256Hex(ofFileAt: url) }
    }
}
