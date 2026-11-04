import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

extension DiskHeavyTests {
    /// Hundreds of random page and annotation changes, undos, redos and
    /// restored page orders. After each one, nothing that should be there is
    /// lost, and every annotation is still on the page it was made on.
    struct PageStressTests {
        /// Random, but the same every run.
        struct SplitMix64: RandomNumberGenerator {
            var state: UInt64

            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }

        /// What a window holds: each page's content and ID, and the
        /// annotations.
        struct Document {
            var contents: [String]
            var pageIDs: [UUID]
            var annotations: [Annotation]
        }

        /// Everything known about the pages and annotations ever made.
        final class World {
            var random: SplitMix64
            /// The content shown on each page ID; it never changes.
            var content: [UUID: String] = [:]
            /// The content of the page each annotation was made on.
            var madeOn: [UUID: String] = [:]
            private var made = 0

            init(seed: UInt64) { random = SplitMix64(state: seed) }

            func document(_ name: String, pages: Int) -> Document {
                let ids = (0..<pages).map { _ in UUID() }
                let contents = (0..<pages).map { "\(name)\($0)" }
                for (id, text) in zip(ids, contents) { content[id] = text }
                return Document(
                    contents: contents, pageIDs: ids, annotations: [])
            }

            func annotate(_ document: inout Document, page: Int) {
                made += 1
                let annotation = Annotation(
                    kind: made % 3 == 0
                        ? .textBox(text: "note \(made)", fontSize: 12)
                        : .highlight,
                    pageIndex: page,
                    bounds: CGRect(
                        x: 72, y: 700 - made % 40, width: 90, height: 12),
                    color: RGBAColor(red: 1, green: 0.9, blue: 0.3),
                    groupID: made % 4 == 0 ? UUID() : nil)
                document.annotations.append(annotation)
                madeOn[annotation.id] = document.contents[page]
            }

            func pages(of document: Document) -> [Int] {
                let count = Int.random(
                    in: 1...max(1, document.contents.count / 2), using: &random
                )
                return Array(
                    document.contents.indices.shuffled(using: &random)
                        .prefix(count))
            }

            /// The change the app makes, and the checks that nothing went
            /// missing.
            func change(
                _ document: inout Document, _ arrangement: PageArrangement,
                pasting source: Document? = nil, pages copied: [Int] = []
            ) {
                let before = document
                let pasted =
                    source.map { $0.annotations.onPages(copied) } ?? []
                let annotations = before.annotations.arranged(
                    for: arrangement, pasted: pasted)
                document.pageIDs = arrangement.pageIDs(from: before.pageIDs)
                document.contents = arrangement.pages.map {
                    switch $0 {
                    case .existing(let index): before.contents[index]
                    case .pasted(let index): source!.contents[copied[index]]
                    }
                }
                for (id, text) in zip(document.pageIDs, document.contents)
                where content[id] == nil {
                    content[id] = text
                }
                let copies = annotations.suffix(pasted.count)
                for (copy, original) in zip(copies, pasted) {
                    madeOn[copy.id] = madeOn[original.id]
                }
                document.annotations = annotations

                let kept = Set(document.pageIDs)
                let survivors = before.annotations.filter {
                    kept.contains(before.pageIDs[$0.pageIndex])
                }
                #expect(
                    Array(annotations.prefix(survivors.count)).map(\.id)
                        == survivors.map(\.id))
                #expect(annotations.count == survivors.count + pasted.count)
            }

            func check(_ document: Document) {
                #expect(document.contents.count == document.pageIDs.count)
                #expect(Set(document.pageIDs).count == document.pageIDs.count)
                for (id, text) in zip(document.pageIDs, document.contents) {
                    #expect(content[id] == text)
                }
                let ids = document.annotations.map(\.id)
                #expect(Set(ids).count == ids.count)
                for annotation in document.annotations {
                    #expect(
                        document.contents.indices.contains(
                            annotation.pageIndex))
                    #expect(
                        document.contents[annotation.pageIndex]
                            == madeOn[annotation.id])
                }
            }
        }

        @Test(arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
        func randomChangesLoseNothing(seed: UInt64) {
            let world = World(seed: seed)
            var document = world.document("A", pages: 8)
            var other = world.document("B", pages: 5)
            for page in 0..<5 { world.annotate(&other, page: page) }
            var undo: [Document] = []
            var redo: [Document] = []
            /// Page orders left behind, as the version history keeps them.
            var earlierOrders: [Document] = []

            for _ in 0..<400 {
                let before = document
                let count = document.contents.count
                switch Int.random(in: 0..<10, using: &world.random) {
                case 0, 1:
                    world.annotate(
                        &document,
                        page: Int.random(in: 0..<count, using: &world.random))
                case 2:
                    guard !document.annotations.isEmpty else { continue }
                    document.annotations.remove(
                        at: Int.random(
                            in: document.annotations.indices,
                            using: &world.random)
                    )
                case 3:
                    world.change(
                        &document,
                        .moving(
                            world.pages(of: document),
                            to: Int.random(
                                in: 0...count, using: &world.random),
                            pageCount: count))
                case 4:
                    let pages = world.pages(of: document)
                    guard pages.count < count else { continue }
                    world.change(&document, .deleting(pages, pageCount: count))
                case 5, 6:
                    // from the other window, or a copy within this one
                    let source =
                        Bool.random(using: &world.random) ? other : document
                    let pages = world.pages(of: source)
                    world.change(
                        &document,
                        .inserting(
                            pages.count,
                            at: Int.random(
                                in: 0...count, using: &world.random),
                            pageCount: count),
                        pasting: source, pages: pages)
                case 7:
                    guard let last = undo.popLast() else { continue }
                    redo.append(document)
                    document = last
                    if last.pageIDs != before.pageIDs {
                        earlierOrders.append(before)
                    }
                    world.check(document)
                    continue
                case 8:
                    guard let next = redo.popLast() else { continue }
                    undo.append(document)
                    document = next
                    if next.pageIDs != before.pageIDs {
                        earlierOrders.append(before)
                    }
                    world.check(document)
                    continue
                default:
                    guard
                        let earlier = earlierOrders.randomElement(
                            using: &world.random),
                        earlier.pageIDs != document.pageIDs
                    else { continue }
                    document.annotations = before.annotations.restoringPages(
                        earlier.pageIDs, from: before.pageIDs,
                        earlier: earlier.annotations)
                    document.pageIDs = earlier.pageIDs
                    document.contents = earlier.contents
                    // today's annotations on pages still there, and the
                    // earlier ones on pages that come back
                    let restored = Set(earlier.pageIDs)
                    let current = Set(before.pageIDs)
                    let expected =
                        before.annotations.filter {
                            restored.contains(before.pageIDs[$0.pageIndex])
                        }.map(\.id)
                        + earlier.annotations.filter {
                            !current.contains(earlier.pageIDs[$0.pageIndex])
                        }.map(\.id)
                    #expect(document.annotations.map(\.id) == expected)
                }
                if document.pageIDs != before.pageIDs {
                    earlierOrders.append(before)
                }
                undo.append(before)
                redo.removeAll()
                world.check(document)
            }
        }

        /// The store side of the same: page changes back and forth between
        /// orders already seen, each saved as the app does, then loaded again.
        @Test func everyPageOrderLoadsWhatWasLastSavedForIt() async throws {
            let root = makeTemporaryRoot()
            let clock = FakeClock()
            let store = AnnotationStore(rootURL: root, now: clock.now)
            var random = SplitMix64(state: 42)
            let document = UUID()
            func hash(_ order: Int) -> String {
                String(format: "%064x", order + 1)
            }
            func pdf(_ order: Int) -> Data {
                Data("PDF of order \(order)".utf8)
            }
            let identities = (0..<6).map { _ in
                PageIdentity(documentID: document, pageIDs: [UUID()])
            }
            var expected: [Int: [Annotation]] = [:]
            var current = 0
            var set = makeSet(hash: hash(0), revision: 1)
            try await store.save(set)

            for step in 0..<60 {
                clock.advance(by: 30)
                if Bool.random(using: &random) {
                    // an annotation change, saved by autosave
                    set.annotations.append(
                        Annotation(
                            kind: .highlight, pageIndex: step % 12,
                            bounds: CGRect(
                                x: 72, y: 700, width: 50, height: 12),
                            color: RGBAColor(red: 1, green: 1, blue: 0)))
                    set.revision += 1
                    #expect(try await store.save(set))
                } else {
                    // a page change to one of six orders, often one seen
                    // before
                    let next = Int.random(in: 0..<6, using: &random)
                    guard next != current else { continue }
                    set = try await store.leavePages(
                        set, identity: identities[current], pdf: pdf(current))
                    expected[current] = set.annotations
                    set.documentHash = hash(next)
                    set = try await store.saveAfterPageChange(set)
                    current = next
                }
                expected[current] = set.annotations
            }
            for (order, annotations) in expected {
                let loaded = await store.load(documentHash: hash(order)).set
                #expect(loaded?.annotations == annotations)
            }
            for layout in await store.pageOrders(of: document) {
                let order = Int(layout.documentHash, radix: 16)! - 1
                #expect(layout.identity == identities[order])
                if let url = layout.pdfURL {
                    #expect(try Data(contentsOf: url) == pdf(order))
                }
            }
        }
    }
}
