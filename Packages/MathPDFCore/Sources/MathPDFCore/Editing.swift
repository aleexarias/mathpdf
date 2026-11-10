import CoreGraphics
import Foundation

/// A change to a document's annotations, worked out from the current ones. The
/// app applies it and registers its undo; nothing here touches the screen or
/// the disk.
public struct AnnotationEdit: Equatable, Sendable {
    public enum Undo: Equatable, Sendable {
        /// Undo goes back to the annotations as they were before.
        case toPrevious
        /// Undo goes back to these instead: undoing a finished note goes back
        /// to before it was begun.
        case to([Annotation])
        /// Not undoable by itself: a note or formula being written, or one
        /// dropped unfinished.
        case none
    }

    public var annotations: [Annotation]
    /// For the Edit menu: "Undo Highlight", "Undo Move", …
    public var actionName: String
    public var undo: Undo

    public init(
        annotations: [Annotation], actionName: String, undo: Undo = .toPrevious
    ) {
        self.annotations = annotations
        self.actionName = actionName
        self.undo = undo
    }
}

extension Annotation {
    /// What the user selects, moves and deletes as one: all lines of a
    /// multi-line markup.
    public var itemID: UUID { groupID ?? id }

    /// Notes always stay light yellow.
    public var isRecolorable: Bool {
        if case .note = kind { return false }
        return true
    }

    /// Formulas and text boxes can be dragged around. Highlights, underlines
    /// and notes stay with their text.
    public var isMovable: Bool {
        switch kind {
        case .latex, .textBox: true
        case .highlight, .underline, .note: false
        }
    }

    /// Where a click selects this annotation.
    public var hitRects: [CGRect] {
        if case .note(_, let anchors) = kind { return [bounds] + anchors }
        return [bounds]
    }
}

/// The changes the app makes. Each returns nil when it wouldn't change
/// anything.
extension [Annotation] {
    /// The topmost annotation under a point on a page. `hitRects` says where
    /// each one counts as clicked; by default, everywhere it's drawn.
    public func annotation(
        at point: CGPoint, pageIndex: Int,
        hitRects: (Annotation) -> [CGRect] = { $0.hitRects }
    ) -> Annotation? {
        last { annotation in
            annotation.pageIndex == pageIndex
                && hitRects(annotation).contains {
                    $0.insetBy(dx: -2, dy: -2).contains(point)
                }
        }
    }

    public func item(_ itemID: UUID) -> [Annotation] {
        filter { $0.itemID == itemID }
    }

    /// One annotation per selected line. The lines share a group, so they act
    /// as one item.
    public func addingMarkup(
        _ kind: Annotation.Kind, lines: [(pageIndex: Int, rect: CGRect)],
        color: RGBAColor
    ) -> AnnotationEdit? {
        guard !lines.isEmpty else { return nil }
        let groupID = lines.count > 1 ? UUID() : nil
        let now = Timestamp.now()
        let added = lines.map {
            Annotation(
                kind: kind, pageIndex: $0.pageIndex, bounds: $0.rect,
                color: color, groupID: groupID, createdAt: now)
        }
        return AnnotationEdit(
            annotations: self + added,
            actionName: kind == .underline ? "Underline" : "Highlight")
    }

    /// A note while its text is being written. It only becomes an undoable
    /// "Add Note" when `finishingNote` gets some text; left empty, it
    /// disappears.
    public func beginningNote(
        pageIndex: Int, iconRect: CGRect, anchorRects: [CGRect],
        color: RGBAColor
    ) -> (edit: AnnotationEdit, id: UUID) {
        let note = Annotation(
            kind: .note(text: "", anchorRects: anchorRects),
            pageIndex: pageIndex, bounds: iconRect, color: color)
        return (
            AnnotationEdit(
                annotations: self + [note], actionName: "Add Note", undo: .none
            ), note.id
        )
    }

    public func finishingNote(_ id: UUID, text: String, isNew: Bool)
        -> AnnotationEdit?
    {
        guard let index = firstIndex(where: { $0.id == id }),
            case .note(let oldText, let anchors) = self[index].kind
        else { return nil }
        let without = filter { $0.id != id }
        if isNew, text.isBlank {
            return AnnotationEdit(
                annotations: without, actionName: "Add Note", undo: .none)
        }
        guard isNew || text != oldText else { return nil }
        var updated = self
        updated[index].kind = .note(text: text, anchorRects: anchors)
        updated[index].modifiedAt = Timestamp.now()
        return isNew
            ? AnnotationEdit(
                annotations: updated, actionName: "Add Note",
                undo: .to(without))
            : AnnotationEdit(annotations: updated, actionName: "Edit Note")
    }

    /// A formula while its source is being written; like a note, it only
    /// becomes an undoable "Add LaTeX" once `finishingLaTeX` gets some source.
    public func beginningLaTeX(
        pageIndex: Int, bounds: CGRect, fontSize: Double, color: RGBAColor
    ) -> (edit: AnnotationEdit, id: UUID) {
        beginning(
            .latex(source: "", fontSize: fontSize), pageIndex: pageIndex,
            bounds: bounds, color: color, actionName: "Add LaTeX")
    }

    /// `size` is the typeset size; the formula keeps its top-left corner when
    /// it changes size, unless that would take it off `page`. An empty formula
    /// is deleted: a new one without a trace, an existing one undoably.
    public func finishingLaTeX(
        _ id: UUID, source: String, expanded: String? = nil, fontSize: Double,
        size: CGSize, isNew: Bool, within page: PageFrame? = nil
    ) -> AnnotationEdit? {
        finishing(
            id,
            as: .latex(
                source: source, fontSize: fontSize,
                expanded: expanded == source ? nil : expanded),
            isEmpty: source.isBlank, size: size, page: page, isNew: isNew,
            noun: "LaTeX"
        )
    }

    /// A text box while its text is being written, like a formula.
    public func beginningTextBox(
        pageIndex: Int, bounds: CGRect, fontSize: Double, color: RGBAColor
    ) -> (edit: AnnotationEdit, id: UUID) {
        beginning(
            .textBox(text: "", fontSize: fontSize), pageIndex: pageIndex,
            bounds: bounds, color: color, actionName: "Add Text")
    }

    /// Like `finishingLaTeX`: `size` is the size the text needs, and an empty
    /// text box is deleted.
    public func finishingTextBox(
        _ id: UUID, text: String, expanded: String? = nil, fontSize: Double,
        size: CGSize, isNew: Bool, within page: PageFrame? = nil
    ) -> AnnotationEdit? {
        finishing(
            id,
            as: .textBox(
                text: text, fontSize: fontSize,
                expanded: expanded == text ? nil : expanded),
            isEmpty: text.isBlank, size: size, page: page, isNew: isNew,
            noun: "Text")
    }

    private func beginning(
        _ kind: Annotation.Kind, pageIndex: Int, bounds: CGRect,
        color: RGBAColor, actionName: String
    ) -> (
        edit: AnnotationEdit, id: UUID
    ) {
        let annotation = Annotation(
            kind: kind, pageIndex: pageIndex, bounds: bounds, color: color)
        return (
            AnnotationEdit(
                annotations: self + [annotation], actionName: actionName,
                undo: .none), annotation.id
        )
    }

    /// Finishes a formula or text box: keeps its top-left corner as it changes
    /// size (moving it in as little as needed if it would leave the page), and
    /// deletes it if it's empty (a new one without a trace, an existing one
    /// undoably).
    private func finishing(
        _ id: UUID, as kind: Annotation.Kind, isEmpty: Bool, size: CGSize,
        page: PageFrame?, isNew: Bool, noun: String
    ) -> AnnotationEdit? {
        guard let index = firstIndex(where: { $0.id == id }),
            self[index].kind.isSameKind(as: kind)
        else { return nil }
        let without = filter { $0.id != id }
        if isEmpty {
            return isNew
                ? AnnotationEdit(
                    annotations: without, actionName: "Add \(noun)",
                    undo: .none)
                : AnnotationEdit(
                    annotations: without, actionName: "Delete \(noun)")
        }
        guard isNew || kind != self[index].kind else { return nil }
        var updated = self
        updated[index].kind = kind
        updated[index].bounds = Self.resized(
            updated[index].bounds, to: size, aroundCentre: isNew, within: page)
        updated[index].modifiedAt = Timestamp.now()
        return isNew
            ? AnnotationEdit(
                annotations: updated, actionName: "Add \(noun)",
                undo: .to(without))
            : AnnotationEdit(annotations: updated, actionName: "Edit \(noun)")
    }

    /// A text box at a new size (its width set by hand, its height following
    /// its wrapped text), keeping its top-left corner unless that would take
    /// it off `page`.
    public func resizingTextBox(
        _ id: UUID, to size: CGSize, within page: PageFrame? = nil
    ) -> AnnotationEdit? {
        guard let index = firstIndex(where: { $0.id == id }),
            case .textBox = self[index].kind,
            self[index].bounds.size != page?.turned(size) ?? size
        else { return nil }
        var updated = self
        updated[index].bounds = Self.resized(
            updated[index].bounds, to: size, within: page)
        updated[index].modifiedAt = Timestamp.now()
        return AnnotationEdit(annotations: updated, actionName: "Resize Text")
    }

    /// `bounds` at a new size on screen with the same top-left corner on
    /// screen, or the same centre, moved in as little as needed to stay on
    /// `page`.
    private static func resized(
        _ bounds: CGRect, to size: CGSize, aroundCentre: Bool = false,
        within page: PageFrame?
    ) -> CGRect {
        let shown = page?.shown(bounds) ?? bounds
        let resized = CGRect(
            x: aroundCentre ? shown.midX - size.width / 2 : shown.minX,
            y: aroundCentre
                ? shown.midY - size.height / 2 : shown.maxY - size.height,
            width: size.width, height: size.height)
        guard let page else { return resized }
        return page.onPage(page.keptOnPage(resized))
    }

    /// Moves all of an item; a note's text anchors move with it.
    public func movingItem(_ itemID: UUID, by offset: CGSize)
        -> AnnotationEdit?
    {
        guard offset != .zero else { return nil }
        return updatingItem(itemID, actionName: "Move") { annotation in
            annotation.bounds = annotation.bounds.offsetBy(
                dx: offset.width, dy: offset.height)
            if case let .note(text, anchors) = annotation.kind {
                annotation.kind = .note(
                    text: text,
                    anchorRects: anchors.map {
                        $0.offsetBy(dx: offset.width, dy: offset.height)
                    })
            }
        }
    }

    public func recoloringItem(_ itemID: UUID, to color: RGBAColor)
        -> AnnotationEdit?
    {
        guard item(itemID).contains(where: { $0.color != color }) else {
            return nil
        }
        return updatingItem(itemID, actionName: "Change Colour") {
            $0.color = color
        }
    }

    public func deletingItem(_ itemID: UUID) -> AnnotationEdit? {
        let remaining = filter { $0.itemID != itemID }
        return remaining.count == count
            ? nil
            : AnnotationEdit(annotations: remaining, actionName: "Delete")
    }

    /// Puts back the annotations of an earlier version, as one undoable step.
    public func restoringVersion(_ version: [Annotation]) -> AnnotationEdit? {
        version == self
            ? nil
            : AnnotationEdit(
                annotations: version, actionName: "Restore Version")
    }

    /// Puts annotations saved for another PDF onto this one, as one undoable
    /// step, given the box of each of its pages. What has no page to be on,
    /// or would be off its page, can't be seen or reached here and is left
    /// out. Nil if that's all of them.
    public func relinking(_ source: [Annotation], pageBoxes: [CGRect])
        -> (edit: AnnotationEdit, leftOut: Int)?
    {
        let fitting = source.filter {
            pageBoxes.indices.contains($0.pageIndex)
                && pageBoxes[$0.pageIndex].intersects($0.bounds)
        }
        guard !fitting.isEmpty else { return nil }
        return (
            AnnotationEdit(annotations: fitting, actionName: "Relink"),
            source.count - fitting.count
        )
    }

    private func updatingItem(
        _ itemID: UUID, actionName: String,
        _ change: (inout Annotation) -> Void
    ) -> AnnotationEdit? {
        guard contains(where: { $0.itemID == itemID }) else { return nil }
        let now = Timestamp.now()
        return AnnotationEdit(
            annotations: map { annotation in
                guard annotation.itemID == itemID else { return annotation }
                var changed = annotation
                change(&changed)
                changed.modifiedAt = now
                return changed
            }, actionName: actionName)
    }
}

extension Annotation.Kind {
    /// The same sort of annotation, whatever its contents.
    func isSameKind(as other: Self) -> Bool {
        switch (self, other) {
        case (.underline, .underline), (.highlight, .highlight),
            (.note, .note), (.latex, .latex), (.textBox, .textBox):
            true
        default: false
        }
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
