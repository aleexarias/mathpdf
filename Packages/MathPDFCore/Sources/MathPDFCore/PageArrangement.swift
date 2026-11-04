import Foundation

/// A document's pages after some are moved, deleted or pasted: where each
/// page in the new order comes from.
public struct PageArrangement: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A page of the document as it was.
        case existing(Int)
        /// A page of the pages being pasted.
        case pasted(Int)
    }

    public var pages: [Source]

    public init(_ pages: [Source]) {
        self.pages = pages
    }

    /// Takes `moved` out, in their current order, and puts them back before
    /// the page now at `destination` (`pageCount` puts them at the end).
    public static func moving(
        _ moved: [Int], to destination: Int, pageCount: Int
    ) -> Self {
        let moved = Set(moved).filter { (0..<pageCount).contains($0) }
        let rest = (0..<pageCount).filter { !moved.contains($0) }
        let split = rest.count { $0 < destination }
        let order = rest[..<split] + moved.sorted() + rest[split...]
        return Self(order.map { .existing($0) })
    }

    public static func deleting(_ deleted: [Int], pageCount: Int) -> Self {
        let deleted = Set(deleted)
        return Self(
            (0..<pageCount).filter { !deleted.contains($0) }.map {
                .existing($0)
            })
    }

    /// `count` pasted pages, put in before the page now at `index`.
    public static func inserting(_ count: Int, at index: Int, pageCount: Int)
        -> Self
    {
        let index = min(max(index, 0), pageCount)
        let before = (0..<index).map { Source.existing($0) }
        let after = (index..<pageCount).map { Source.existing($0) }
        return Self(before + (0..<count).map { .pasted($0) } + after)
    }

    /// Where each page of the old document ended up; nil if it was deleted.
    public func newIndices(pageCount: Int) -> [Int?] {
        var indices = [Int?](repeating: nil, count: pageCount)
        for (index, source) in pages.enumerated() {
            if case .existing(let old) = source, indices.indices.contains(old)
            {
                indices[old] = index
            }
        }
        return indices
    }

    /// Where each page goes back to, from `newIndices`, where each page
    /// went: what undoing a change needs. `count` is the new page count.
    public static func inverse(of newIndices: [Int?], count: Int) -> [Int?] {
        var inverse = [Int?](repeating: nil, count: count)
        for case (let old, let new?) in newIndices.enumerated()
        where inverse.indices.contains(new) {
            inverse[new] = old
        }
        return inverse
    }

    public func changesNothing(pageCount: Int) -> Bool {
        pages == (0..<pageCount).map { .existing($0) }
    }

    /// The page IDs of the new order: a page keeps its ID wherever it goes,
    /// and a pasted page gets a new one.
    public func pageIDs(from ids: [UUID]) -> [UUID] {
        pages.map {
            switch $0 {
            case .existing(let index) where ids.indices.contains(index):
                ids[index]
            case .existing, .pasted: UUID()
            }
        }
    }
}

extension [Annotation] {
    /// The annotations that go with `arrangement`. Each page's annotations
    /// move with it and a deleted page's are dropped. Pasted pages bring
    /// `pasted`, numbered by pasted page, as new items: pasting the same pages
    /// twice gives two independent copies.
    public func arranged(
        for arrangement: PageArrangement, pasted: [Annotation] = []
    ) -> [Annotation] {
        var existingIndex: [Int: Int] = [:]
        var pastedIndex: [Int: Int] = [:]
        for (index, source) in arrangement.pages.enumerated() {
            switch source {
            case .existing(let page): existingIndex[page] = index
            case .pasted(let page): pastedIndex[page] = index
            }
        }
        let kept = renumbered(existingIndex)
        var groups: [UUID: UUID] = [:]
        let copies = pasted.compactMap { annotation -> Annotation? in
            guard let index = pastedIndex[annotation.pageIndex] else {
                return nil
            }
            var copy = annotation
            copy.id = UUID()
            copy.pageIndex = index
            copy.groupID = annotation.groupID.map { group in
                if let new = groups[group] { return new }
                let new = UUID()
                groups[group] = new
                return new
            }
            return copy
        }
        return kept + copies
    }

    /// These annotations, on pages `from`, put on the same pages in the order
    /// `to`. One whose page isn't in `to` is left out.
    public func moved(fromPages from: [UUID], toPages to: [UUID])
        -> [Annotation]
    {
        var place: [UUID: Int] = [:]
        for (index, id) in to.enumerated() { place[id] = index }
        var newIndex: [Int: Int] = [:]
        for (index, id) in from.enumerated() { newIndex[index] = place[id] }
        return renumbered(newIndex)
    }

    /// The annotations for going back to the earlier page order `pages`.
    /// These, on `currentPages`, follow their pages; a page deleted since
    /// comes back with the annotations it had then, from `earlier`.
    /// Annotations on pages added since are left out.
    public func restoringPages(
        _ pages: [UUID], from currentPages: [UUID], earlier: [Annotation]
    ) -> [Annotation] {
        let current = Set(currentPages)
        let returning = earlier.filter {
            pages.indices.contains($0.pageIndex)
                && !current.contains(pages[$0.pageIndex])
        }
        return moved(fromPages: currentPages, toPages: pages) + returning
    }

    /// The annotations on `pages`, numbered by their place in it: what copying
    /// those pages takes along.
    public func onPages(_ pages: [Int]) -> [Annotation] {
        var position: [Int: Int] = [:]
        for (index, page) in pages.enumerated() where position[page] == nil {
            position[page] = index
        }
        return renumbered(position)
    }

    /// These annotations with their pages renumbered by `newIndex`; one whose
    /// page isn't in it is left out.
    private func renumbered(_ newIndex: [Int: Int]) -> [Annotation] {
        compactMap { annotation in
            guard let index = newIndex[annotation.pageIndex] else {
                return nil
            }
            var renumbered = annotation
            renumbered.pageIndex = index
            return renumbered
        }
    }
}
