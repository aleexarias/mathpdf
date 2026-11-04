import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

extension DiskHeavyTests {
    /// Moving, deleting and pasting pages: the new order, and the
    /// annotations that go with each page.
    struct PageTests {
        let yellow = RGBAColor(red: 1, green: 0.9, blue: 0.3)

        func mark(page: Int, group: UUID? = nil) -> Annotation {
            Annotation(
                kind: .highlight, pageIndex: page,
                bounds: CGRect(x: 72, y: 700, width: 200, height: 12),
                color: yellow, groupID: group)
        }

        func order(_ arrangement: PageArrangement) -> [String] {
            arrangement.pages.map {
                switch $0 {
                case .existing(let index): "\(index)"
                case .pasted(let index): "p\(index)"
                }
            }
        }

        @Test func movingPutsPagesBeforeTheDestination() {
            #expect(
                order(.moving([4], to: 1, pageCount: 6))
                    == ["0", "4", "1", "2", "3", "5"])
            #expect(
                order(.moving([0, 2], to: 5, pageCount: 6))
                    == ["1", "3", "4", "0", "2", "5"])
            #expect(
                order(.moving([1, 3], to: 6, pageCount: 6))
                    == ["0", "2", "4", "5", "1", "3"])
            // given in any order, moved pages keep their order
            #expect(
                order(.moving([3, 1], to: 0, pageCount: 4))
                    == ["1", "3", "0", "2"])
            for destination in [2, 3] {
                let arrangement = PageArrangement.moving(
                    [2], to: destination, pageCount: 4)
                #expect(arrangement.changesNothing(pageCount: 4))
            }
        }

        @Test func deletingAndInserting() {
            let deleted = PageArrangement.deleting([0, 2], pageCount: 4)
            #expect(order(deleted) == ["1", "3"])
            #expect(deleted.newIndices(pageCount: 4) == [nil, 0, nil, 1])
            #expect(
                order(.inserting(2, at: 1, pageCount: 3))
                    == ["0", "p0", "p1", "1", "2"])
            #expect(
                order(.inserting(1, at: 3, pageCount: 3))
                    == ["0", "1", "2", "p0"])
        }

        @Test func undoingSendsEachPageBack() {
            let arrangement = PageArrangement.deleting([1], pageCount: 4)
            let newIndices = arrangement.newIndices(pageCount: 4)
            #expect(newIndices == [0, nil, 1, 2])
            #expect(
                PageArrangement.inverse(of: newIndices, count: 3) == [0, 2, 3])
            let moved = PageArrangement.moving([0], to: 3, pageCount: 3)
                .newIndices(pageCount: 3)
            let back = PageArrangement.inverse(of: moved, count: 3)
            #expect(moved.indices.allSatisfy { back[moved[$0]!] == $0 })
        }

        @Test func annotationsMoveWithTheirPages() {
            let annotations = [mark(page: 0), mark(page: 1), mark(page: 2)]
            let moved = annotations.arranged(
                for: .moving([2], to: 0, pageCount: 3))
            #expect(moved.map(\.pageIndex) == [1, 2, 0])
            #expect(moved.map(\.id) == annotations.map(\.id))

            let deleted = annotations.arranged(
                for: .deleting([1], pageCount: 3))
            #expect(deleted.map(\.pageIndex) == [0, 1])
            #expect(
                deleted.map(\.id) == [annotations[0].id, annotations[2].id])
        }

        @Test func pastedAnnotationsAreNewItems() {
            let group = UUID()
            let copied = [
                mark(page: 0, group: group), mark(page: 1, group: group),
            ]
            let existing = [mark(page: 0)]
            let arrangement = PageArrangement.inserting(2, at: 0, pageCount: 1)
            let once = existing.arranged(for: arrangement, pasted: copied)
            #expect(once.map(\.pageIndex) == [2, 0, 1])
            #expect(once[0].id == existing[0].id)
            let pasted = Array(once.dropFirst())
            #expect(Set(pasted.map(\.id)).isDisjoint(with: copied.map(\.id)))
            // still one item, but not the copied one
            #expect(pasted[0].groupID != nil)
            #expect(pasted[0].groupID == pasted[1].groupID)
            #expect(pasted[0].groupID != group)

            let twice = once.arranged(
                for: .inserting(2, at: 3, pageCount: 3), pasted: copied)
            #expect(Set(twice.compactMap(\.groupID)).count == 2)
            #expect(Set(twice.map(\.id)).count == 5)
        }

        @Test func copyingPagesTakesTheirAnnotations() {
            let annotations = [mark(page: 0), mark(page: 3), mark(page: 5)]
            let copied = annotations.onPages([5, 3])
            #expect(copied.map(\.pageIndex) == [1, 0])
            #expect(
                copied.map(\.id) == [annotations[1].id, annotations[2].id])
        }

        @Test func copiedAnnotationsRoundTrip() throws {
            let annotations = [mark(page: 0), mark(page: 1, group: UUID())]
            let data = try CopiedAnnotations.encode(annotations, pageCount: 2)
            let decoded = try #require(CopiedAnnotations.decode(data))
            #expect(decoded.pageCount == 2)
            #expect(decoded.annotations == annotations)
            #expect(CopiedAnnotations.decode(Data("{}".utf8)) == nil)
            let newer = Data(
                String(decoding: data, as: UTF8.self).replacingOccurrences(
                    of: "\"version\" : 1", with: "\"version\" : 2"
                ).utf8)
            #expect(CopiedAnnotations.decode(newer) == nil)
        }

        @Test func savingAfterAPageChangeGoesPastWhatIsStored() async throws {
            let root = makeTemporaryRoot()
            let store = AnnotationStore(rootURL: root)
            let other = String(repeating: "cd", count: 32)
            try await store.save(makeSet(hash: other, revision: 9))

            let moved = try await store.saveAfterPageChange(
                makeSet(hash: other, revision: 4, annotations: [mark(page: 0)])
            )
            #expect(moved.revision == 10)
            let loaded = await store.load(documentHash: other).set
            #expect(loaded?.annotations == moved.annotations)
            #expect(loaded?.revision == 10)

            let fresh = String(repeating: "ef", count: 32)
            let first = try await store.saveAfterPageChange(
                makeSet(hash: fresh, revision: 4))
            #expect(first.revision == 5)
        }

        @Test func pagesKeepTheirIDsAndPastedOnesGetNewOnes() {
            let ids = (0..<3).map { _ in UUID() }
            let moved = PageArrangement.moving([2], to: 0, pageCount: 3)
            #expect(moved.pageIDs(from: ids) == [ids[2], ids[0], ids[1]])
            let pasted = PageArrangement.inserting(1, at: 1, pageCount: 3)
                .pageIDs(from: ids)
            #expect(pasted.count == 4)
            #expect(
                pasted[0] == ids[0] && Array(pasted[2...]) == [ids[1], ids[2]])
            #expect(!ids.contains(pasted[1]))
        }

        @Test func annotationsFollowPageIDsToAnotherOrder() {
            let ids = (0..<3).map { _ in UUID() }
            let annotations = [mark(page: 0), mark(page: 1), mark(page: 2)]
            let other = [ids[2], UUID(), ids[0]]
            let moved = annotations.moved(fromPages: ids, toPages: other)
            #expect(moved.map(\.id) == [annotations[0].id, annotations[2].id])
            #expect(moved.map(\.pageIndex) == [2, 0])
        }

        /// Going back to an earlier page order keeps today's annotations, and
        /// a page deleted since comes back with the annotations it had.
        @Test func restoringPagesKeepsTheCurrentAnnotations() {
            let a = UUID(), b = UUID(), c = UUID(), pasted = UUID()
            let earlierPages = [a, b, c]
            let onB = mark(page: 1)
            let earlier = [mark(page: 0), onB]
            // since then: b deleted, c moved first, a page pasted, new
            // annotations made
            let currentPages = [c, a, pasted]
            let onC = mark(page: 0), onA = mark(page: 1),
                onPasted = mark(page: 2)
            let restored = [onC, onA, onPasted].restoringPages(
                earlierPages, from: currentPages, earlier: earlier)
            #expect(restored.map(\.id) == [onC.id, onA.id, onB.id])
            #expect(restored.map(\.pageIndex) == [2, 0, 1])
        }

        @Test func pageOrdersAreKeptAndListed() async throws {
            let root = makeTemporaryRoot()
            let clock = FakeClock()
            let store = AnnotationStore(rootURL: root, now: clock.now)
            let document = UUID()
            let first = PageIdentity(
                documentID: document, pageIDs: [UUID(), UUID()])
            let pdf = Data("first PDF".utf8)
            try await store.leavePages(
                makeSet(hash: testHash, revision: 1), identity: first, pdf: pdf
            )
            let second = String(repeating: "cd", count: 32)
            let identity = PageIdentity(
                documentID: document, pageIDs: first.pageIDs.reversed())
            try await store.savePageIdentity(identity, documentHash: second)

            #expect(await store.pageIdentity(documentHash: testHash) == first)
            let layouts = await store.pageOrders(of: document)
            #expect(layouts.map(\.documentHash) == [second, testHash])
            #expect(layouts[0].pdfURL == nil)
            let kept = try #require(layouts[1].pdfURL)
            #expect(try Data(contentsOf: kept) == pdf)
            #expect(layouts[1].leftAt == clock.now())
            #expect(await store.pageOrders(of: UUID()).isEmpty)
        }

        /// The versions of all page orders count as one history: at least five
        /// in all, not five per page order. Orders with no versions left go,
        /// and the first page order, with the first version, always stays.
        @Test func allPageOrdersShareOneHistory() async throws {
            let root = makeTemporaryRoot()
            let clock = FakeClock()
            let store = AnnotationStore(rootURL: root, now: clock.now)
            let document = UUID()
            func hash(_ order: Int) -> String {
                String(format: "%064x", order + 1)
            }
            // Opened and moved straight away: nothing saved in the first
            // order.
            var set = makeSet(hash: hash(0), revision: 0)
            for order in 0..<4 {
                set = try await store.leavePages(
                    set,
                    identity: PageIdentity(
                        documentID: document, pageIDs: [UUID()]),
                    pdf: Data("PDF \(order)".utf8))
                set.documentHash = hash(order + 1)
                set = try await store.saveAfterPageChange(set)
                try await store.savePageIdentity(
                    PageIdentity(documentID: document, pageIDs: [UUID()]),
                    documentHash: hash(order + 1))
                clock.advance(by: 2 * 24 * 3600)
            }
            // then weeks of work in the last order
            for _ in 0..<6 {
                clock.advance(by: 10 * 24 * 3600)
                set.revision += 1
                try await store.save(set)
            }

            let orders = await store.pageOrders(of: document)
            #expect(Set(orders.map(\.documentHash)) == [hash(0), hash(4)])
            let first = try #require(
                orders.first { $0.documentHash == hash(0) })
            #expect(
                try Data(contentsOf: try #require(first.pdfURL))
                    == Data("PDF 0".utf8))
            let kept =
                await store.snapshots(documentHash: hash(0)).count
                + store.snapshots(documentHash: hash(4)).count
            #expect(kept == 5)
            let firstVersion = try #require(
                await store.snapshots(documentHash: hash(0)).first)
            // saved in the same instant as the next order's, and still the
            // first
            #expect(
                firstVersion.date
                    == Timestamp.parse("2026-11-03T12:00:00.000Z"))
            #expect(await store.snapshots(documentHash: hash(0)).count == 1)
            for gone in 1...3 {
                #expect(
                    !FileManager.default.fileExists(
                        atPath: store.folderURL(hash(gone)).path))
            }
        }

        /// A page change saves the first order's version and the next order's
        /// in the same instant. The first must still sort as the older, or
        /// thinning out could take the original pages.
        @Test func theFirstOrderStaysOlderThanTheNext() async throws {
            let store = AnnotationStore(
                rootURL: makeTemporaryRoot(), now: FakeClock().now)
            var next = try await store.leavePages(
                makeSet(revision: 0), identity: PageIdentity(pageCount: 1),
                pdf: Data("PDF".utf8))
            next.documentHash = String(repeating: "cd", count: 32)
            next = try await store.saveAfterPageChange(next)
            let first = try #require(
                await store.snapshots(documentHash: testHash).first)
            let second = try #require(
                await store.snapshots(documentHash: next.documentHash).first)
            #expect(first.date == second.date)
            #expect(first.revision < second.revision)
        }

        /// Leaves `count` page orders, `every` seconds apart, each kept as a
        /// copy of `copySize` bytes, the way the app saves a page change.
        /// Returns their hashes, the current order's last.
        func changePages(
            _ count: Int, copySize: Int, every step: TimeInterval,
            in store: AnnotationStore, clock: FakeClock
        ) async throws -> (hashes: [String], set: AnnotationSet) {
            let document = UUID()
            let hashes = (0...count).map { String(format: "%064x", $0 + 1) }
            var set = makeSet(hash: hashes[0], revision: 0)
            for order in 0..<count {
                set = try await store.leavePages(
                    set,
                    identity: PageIdentity(
                        documentID: document, pageIDs: [UUID()]),
                    pdf: Data(repeating: UInt8(order), count: copySize))
                try await store.savePageIdentity(
                    PageIdentity(documentID: document, pageIDs: [UUID()]),
                    documentHash: hashes[order + 1])
                set.documentHash = hashes[order + 1]
                set = try await store.saveAfterPageChange(set)
                clock.advance(by: step)
            }
            return (hashes, set)
        }

        func copies(in store: AnnotationStore, of hash: String) async
            -> Set<String>
        {
            guard
                let id = await store.pageIdentity(documentHash: hash)?
                    .documentID
            else { return [] }
            return Set(
                await store.pageOrders(of: id).filter { $0.pdfURL != nil }
                    .map(\.documentHash))
        }

        @Test func copiesOfABigPDFThinOutSooner() async throws {
            let clock = FakeClock()
            let store = AnnotationStore(
                rootURL: makeTemporaryRoot(), now: clock.now,
                limits: .init(largeSize: 10, totalSize: 1_000_000))
            var (hashes, set) = try await changePages(
                5, copySize: 20, every: 2 * 3600, in: store, clock: clock)
            clock.advance(by: 9 * 24 * 3600)
            set.revision += 1
            try await store.save(set)
            // the first page order, and the newest left
            #expect(
                await copies(in: store, of: hashes[5])
                    == [hashes[0], hashes[4]])
        }

        /// The current order's copy goes first (it's the PDF itself), then
        /// the oldest; the first order's only when it alone is too big.
        @Test func copiesOfADocumentStayWithinTheLimit() async throws {
            let clock = FakeClock()
            let store = AnnotationStore(
                rootURL: makeTemporaryRoot(), now: clock.now,
                limits: .init(largeSize: 1_000_000, totalSize: 100))
            var (hashes, set) = try await changePages(
                4, copySize: 40, every: 3600, in: store, clock: clock)
            #expect(
                await copies(in: store, of: hashes[4])
                    == [hashes[0], hashes[3]])

            // back to the first order, whose copy is then the PDF itself
            set = try await store.leavePages(
                set,
                identity: try #require(
                    await store.pageIdentity(documentHash: hashes[4])),
                pdf: Data(repeating: 9, count: 40))
            set.documentHash = hashes[0]
            set = try await store.saveAfterPageChange(set)
            #expect(
                await copies(in: store, of: hashes[0])
                    == [hashes[3], hashes[4]])

            let tight = AnnotationStore(
                rootURL: makeTemporaryRoot(), now: clock.now,
                limits: .init(largeSize: 1_000_000, totalSize: 30))
            let alone = try await changePages(
                1, copySize: 40, every: 3600, in: tight, clock: clock)
            #expect(await copies(in: tight, of: alone.hashes[1]).isEmpty)
            #expect(
                FileManager.default.fileExists(
                    atPath: tight.folderURL(alone.hashes[0]).path))
        }

        /// A document whose pages never changed keeps its history as before.
        @Test func aDocumentWithOnePageOrderIsThinnedOnItsOwn() async throws {
            let root = makeTemporaryRoot()
            let clock = FakeClock()
            let store = AnnotationStore(rootURL: root, now: clock.now)
            var set = makeSet(revision: 0)
            for _ in 0..<12 {
                set.revision += 1
                try await store.save(set)
                clock.advance(by: 5 * 24 * 3600)
            }
            set.revision += 1
            try await store.save(set)
            let left = await store.snapshots(documentHash: testHash)
            #expect(left.count >= 5 && left.count < 13)
            #expect(left.last?.revision == 1)
        }
    }
}
