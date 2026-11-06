import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

@Suite final class MigrationTests: Sendable {
    let root = makeTemporaryRoot()
    let fixtureHash =
        "c4f3689b7171440c27babf13a08bdbcaf0615968a2f71bc520ad8a9271472a8f"

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func v1FixtureMigratesToTheCurrentSchema() throws {
        let decoded = try StoreFile.decode(fixtureData("store-v1"))
        #expect(decoded.schemaVersion == 1)

        let set = decoded.set
        #expect(set.documentHash == fixtureHash)
        #expect(set.pathHint == "/Users/someone/Papers/lecture-notes.pdf")
        #expect(set.fileNameHint == "lecture-notes.pdf")
        #expect(set.pageCount == 3)
        #expect(set.revision == 7)
        #expect(set.savedAt == Timestamp.parse("2025-03-14T09:30:00.000Z"))
        #expect(set.relinkedFrom == nil)
        // the 3-line underline becomes 3 annotations
        #expect(set.annotations.count == 6)

        // One annotation per underlined line, sharing a group. The first keeps
        // the v1 ID.
        let underlines = set.annotations.filter { $0.kind == .underline }
        #expect(underlines.count == 3)
        #expect(
            underlines[0].id
                == UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000001"))
        #expect(Set(underlines.map(\.id)).count == 3)
        #expect(
            underlines.allSatisfy {
                $0.groupID != nil && $0.groupID == underlines[0].groupID
            })
        #expect(
            underlines.map(\.bounds) == [
                CGRect(x: 72, y: 700.5, width: 468, height: 12),
                CGRect(x: 72, y: 686.25, width: 468, height: 12),
                CGRect(x: 72, y: 672, width: 210.75, height: 12),
            ])
        #expect(
            underlines[0].color
                == RGBAColor(
                    red: 1, green: 59.0 / 255, blue: 48.0 / 255, alpha: 1))
        #expect(
            underlines[0].createdAt
                == Timestamp.parse("2025-03-14T09:26:53.589Z"))
        #expect(
            underlines[0].modifiedAt
                == Timestamp.parse("2025-03-14T09:27:10.001Z"))

        let highlight = try #require(
            set.annotations.first { $0.kind == .highlight })
        #expect(highlight.groupID == nil)  // single line: no group
        #expect(highlight.pageIndex == 1)

        let note = try #require(
            set.annotations.first {
                if case .note = $0.kind { true } else { false }
            })
        #expect(
            note.kind
                == .note(
                    text: "Check Itô's lemma here — see §4.2 \"quoted\"",
                    anchorRects: []))

        let latex = try #require(
            set.annotations.first {
                if case .latex = $0.kind { true } else { false }
            })
        let itoSum =
            #"\int_0^T \sigma_t\,dW_t = \lim_{n\to\infty} \sum_{i} "#
            + #"\sigma_{t_i}(W_{t_{i+1}} - W_{t_i}) \quad \text{(Itô)}"#
        #expect(latex.kind == .latex(source: itoSum, fontSize: 14))
        #expect(latex.pageIndex == 2)
    }

    /// A file saved before text boxes existed, written by that version's
    /// encoder, must keep loading exactly as it was.
    @Test func v2FixtureLoadsUnchanged() throws {
        let decoded = try StoreFile.decode(fixtureData("store-v2"))
        #expect(decoded.schemaVersion == 2)
        let set = decoded.set
        func id(_ n: Int) -> UUID {
            let text = String(format: "2A000000-0000-4000-8000-%012d", n)
            return UUID(uuidString: text)!
        }
        let hash =
            "7d1e4c2b9a8f6e5d4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a2918070605"
        #expect(set.documentHash == hash)
        #expect(set.fileNameHint == "lecture-notes.pdf")
        #expect(set.pathHint == "/Users/someone/Lectures/lecture-notes.pdf")
        #expect(set.pageCount == 3)
        #expect(set.revision == 12)
        #expect(set.savedAt == Timestamp.parse("2026-11-03T10:21:00.000Z"))
        #expect(set.annotations.map(\.id) == (1...6).map(id))

        let created = Timestamp.parse("2026-11-03T10:15:00.250Z"),
            edited = Timestamp.parse("2026-11-03T10:20:30.500Z")
        let a = set.annotations
        #expect(a[0].kind == .highlight && a[1].kind == .highlight)
        #expect(a[0].groupID == id(100) && a[1].groupID == id(100))
        #expect(
            a[1].bounds == CGRect(x: 72, y: 685.25, width: 200.5, height: 13.5)
        )
        #expect(a[0].color == RGBAColor(red: 1, green: 0.88, blue: 0.32))
        #expect(a[0].createdAt == created && a[0].modifiedAt == created)
        #expect(
            a[2].kind == .underline && a[2].pageIndex == 1
                && a[2].groupID == nil && a[2].modifiedAt == edited)
        #expect(
            a[3].kind
                == .note(
                    text: "Why is this a martingale?\nCheck the filtration.",
                    anchorRects: [
                        CGRect(x: 72, y: 640, width: 150, height: 12)
                    ]))
        #expect(
            a[4].kind == .note(text: "Point note", anchorRects: [])
                && a[4].pageIndex == 2)
        #expect(
            a[5].kind
                == .latex(
                    source:
                        #"\mathbb{E}\left[\int_0^T \sigma_t\,dW_t\right] = 0"#,
                    fontSize: 18))
        #expect(
            a[5].bounds == CGRect(x: 330, y: 347, width: 154.1, height: 58))
    }

    /// The format as of schema 3, frozen before the next change to it.
    @Test func v3FixtureLoadsUnchanged() throws {
        let decoded = try StoreFile.decode(fixtureData("store-v3"))
        #expect(decoded.schemaVersion == 3)
        let set = decoded.set
        func id(_ n: Int) -> UUID {
            let text = String(format: "3A000000-0000-4000-8000-%012d", n)
            return UUID(uuidString: text)!
        }
        #expect(
            set.documentHash
                == "5e4d3c2b1a09f8e7d6c5b4a39281706f"
                + "5e4d3c2b1a09f8e7d6c5b4a392817060")
        #expect(set.fileNameHint == "problem-set.pdf")
        #expect(set.pageCount == 4)
        #expect(set.revision == 21)
        #expect(set.savedAt == Timestamp.parse("2026-11-04T09:06:00.000Z"))
        #expect(set.annotations.map(\.id) == (1...6).map(id))
        let a = set.annotations
        #expect(a[0].groupID == id(100) && a[1].groupID == id(100))
        #expect(a[2].kind == .underline && a[2].pageIndex == 1)
        #expect(
            a[2].modifiedAt == Timestamp.parse("2026-11-04T09:05:30.750Z"))
        #expect(
            a[3].kind
                == .note(
                    text: "Use Itô's lemma here.",
                    anchorRects: [
                        CGRect(x: 72, y: 600, width: 120, height: 12)
                    ]))
        #expect(
            a[4].kind
                == .latex(
                    source: #"dX_t = \mu X_t\,dt + \sigma X_t\,dW_t"#,
                    fontSize: 16))
        #expect(
            a[5].kind
                == .textBox(text: "Exam question\nsee lecture 7", fontSize: 13)
        )
        #expect(
            a[5].bounds == CGRect(x: 72, y: 300, width: 110, height: 36.5))
        #expect(a[5].color == RGBAColor(red: 0.2, green: 0.4, blue: 0.9))
    }

    /// The format as of schema 4, frozen before the next change to it. It adds
    /// what a formula expanded to; the rest is as in schema 3.
    @Test func v4FixtureLoadsUnchanged() throws {
        let decoded = try StoreFile.decode(fixtureData("store-v4"))
        #expect(decoded.schemaVersion == 4)
        let set = decoded.set
        #expect(set.fileNameHint == "stochastic-calculus.pdf")
        #expect(set.revision == 34)
        #expect(set.savedAt == Timestamp.parse("2026-11-06T10:15:00.000Z"))
        var others = set.annotations
        let formula = others.remove(at: 4)
        #expect(
            formula.kind
                == .latex(
                    source: #"\half\R^n + \norm{x}"#, fontSize: 16,
                    expanded: #"\frac{1}{2}\mathbb{R}^n + \left\|x\right\|"#))
        var earlier = try StoreFile.decode(fixtureData("store-v3")).set
            .annotations
        earlier.remove(at: 4)
        #expect(others == earlier)
    }

    @Test func migrationIsDeterministic() throws {
        let data = try fixtureData("store-v1")
        #expect(try StoreFile.decode(data).set == StoreFile.decode(data).set)
    }

    @Test func tamperedV1FileFailsTheChecksum() throws {
        let text = String(decoding: try fixtureData("store-v1"), as: UTF8.self)
        let tampered = Data(
            text.replacingOccurrences(of: "#FF3B30", with: "#FF3B31").utf8)
        #expect(throws: StoreFileError.checksumMismatch) {
            try StoreFile.decode(tampered)
        }
    }

    @Test func migratedStoreIsWrittenInTheCurrentSchemaOnTheNextSave()
        async throws
    {
        let store = AnnotationStore(rootURL: root)
        try FileManager.default.createDirectory(
            at: store.folderURL(fixtureHash), withIntermediateDirectories: true
        )
        try fixtureData("store-v1").write(to: store.storeURL(fixtureHash))

        guard
            case .loaded(var set, migratedFrom: 1) = await store.load(
                documentHash: fixtureHash)
        else {
            Issue.record("Expected a load migrated from v1")
            return
        }
        set.revision += 1
        try await store.save(set)

        let envelope =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: store.storeURL(fixtureHash)))
            as? [String: Any]
        #expect(
            envelope?["schemaVersion"] as? Int
                == StoreFile.currentSchemaVersion)
        guard
            case .loaded(let reloaded, migratedFrom: nil) =
                await AnnotationStore(rootURL: root).load(
                    documentHash: fixtureHash)
        else {
            Issue.record("Expected a plain load after resaving")
            return
        }
        #expect(reloaded.annotations == set.annotations)
    }
}
