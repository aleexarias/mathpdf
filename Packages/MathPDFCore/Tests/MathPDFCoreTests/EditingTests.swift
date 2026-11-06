import CoreGraphics
import Foundation
import Testing

@testable import MathPDFCore

/// The rules for changing annotations: what each change does, and what undoing
/// it goes back to.
struct EditingTests {
    let yellow = RGBAColor(red: 1, green: 0.9, blue: 0.3)
    let blue = RGBAColor(red: 0.5, green: 0.7, blue: 1)

    @Test func markupIsOneAnnotationPerLineSharingAGroup() throws {
        let lines = [
            (
                pageIndex: 0,
                rect: CGRect(x: 10, y: 700, width: 200, height: 12)
            ),
            (
                pageIndex: 0,
                rect: CGRect(x: 10, y: 686, width: 120, height: 12)
            ),
        ]
        let edit = try #require(
            [Annotation]().addingMarkup(
                .highlight, lines: lines, color: yellow))
        #expect(edit.annotations.count == 2)
        #expect(
            edit.annotations[0].groupID != nil
                && edit.annotations[0].groupID == edit.annotations[1].groupID)
        #expect(edit.actionName == "Highlight")
        #expect(edit.undo == .toPrevious)

        let single = try #require(
            [Annotation]().addingMarkup(
                .underline, lines: Array(lines.prefix(1)), color: yellow))
        #expect(single.annotations[0].groupID == nil)
        #expect(single.actionName == "Underline")
        #expect(
            [Annotation]().addingMarkup(.highlight, lines: [], color: yellow)
                == nil)
    }

    @Test func aNewNoteIsOnlyUndoableOnceItHasText() throws {
        let begun = [Annotation]().beginningNote(
            pageIndex: 0, iconRect: CGRect(x: 0, y: 0, width: 15, height: 15),
            anchorRects: [], color: yellow)
        #expect(begun.edit.undo == .none)

        let finished = try #require(
            begun.edit.annotations.finishingNote(
                begun.id, text: "Check this", isNew: true))
        #expect(finished.undo == .to([]))
        #expect(finished.actionName == "Add Note")
        guard case .note(let text, _) = finished.annotations[0].kind else {
            throw Failure()
        }
        #expect(text == "Check this")

        let abandoned = try #require(
            begun.edit.annotations.finishingNote(
                begun.id, text: "  \n", isNew: true))
        #expect(abandoned.annotations.isEmpty)
        #expect(abandoned.undo == .none)
    }

    @Test func editingANoteIsUndoableUnlessNothingChanged() throws {
        let note = Annotation(
            kind: .note(text: "old", anchorRects: []), pageIndex: 0,
            bounds: .zero, color: yellow)
        let edit = try #require(
            [note].finishingNote(note.id, text: "new", isNew: false))
        #expect(edit.actionName == "Edit Note")
        #expect(edit.undo == .toPrevious)
        #expect(
            [note].finishingNote(note.id, text: "old", isNew: false) == nil)
    }

    @Test func aNewFormulaStaysCentredWhereItWasBegun() throws {
        let begun = [Annotation]().beginningLaTeX(
            pageIndex: 0,
            bounds: CGRect(x: 100, y: 600, width: 60, height: 20),
            fontSize: 16, color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            begun.edit.annotations.finishingLaTeX(
                begun.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 200, height: 40), isNew: true))
        #expect(
            edit.annotations[0].bounds
                == CGRect(x: 30, y: 590, width: 200, height: 40))
        #expect(edit.undo == .to([]))
        #expect(edit.actionName == "Add LaTeX")
    }

    @Test func aNewTextBoxStaysCentredWhereItWasBegun() throws {
        let begun = [Annotation]().beginningTextBox(
            pageIndex: 0,
            bounds: CGRect(x: 100, y: 600, width: 60, height: 20),
            fontSize: 14, color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            begun.edit.annotations.finishingTextBox(
                begun.id, text: "hello", fontSize: 14,
                size: CGSize(width: 200, height: 40), isNew: true))
        #expect(
            edit.annotations[0].bounds
                == CGRect(x: 30, y: 590, width: 200, height: 40))
    }

    /// A big one centred on a small page has to give way.
    @Test func aNewFormulaStillStaysOnItsPage() throws {
        let page = PageFrame(box: CGRect(x: 0, y: 0, width: 300, height: 300))
        let begun = [Annotation]().beginningLaTeX(
            pageIndex: 0,
            bounds: CGRect(x: 120, y: 140, width: 60, height: 20),
            fontSize: 16, color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            begun.edit.annotations.finishingLaTeX(
                begun.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 400, height: 40), isNew: true,
                within: page))
        #expect(edit.annotations[0].bounds.minX == 0)
        #expect(edit.annotations[0].bounds.midY == 150)
    }

    /// Editing a formula that's already placed doesn't move its corner.
    @Test func anEditedFormulaKeepsItsTopLeftCorner() throws {
        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: CGRect(x: 100, y: 600, width: 60, height: 25),
            color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            [formula].finishingLaTeX(
                formula.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 30, height: 40), isNew: false))
        #expect(
            edit.annotations[0].bounds
                // top stays at 625
                == CGRect(x: 100, y: 585, width: 30, height: 40))
    }

    @Test func emptyFormulasAreDeleted() throws {
        let begun = [Annotation]().beginningLaTeX(
            pageIndex: 0, bounds: .zero, fontSize: 16, color: yellow)
        let dropped = try #require(
            begun.edit.annotations.finishingLaTeX(
                begun.id, source: " ", fontSize: 16, size: .zero, isNew: true))
        #expect(dropped.annotations.isEmpty)
        // it never existed as far as undo knows
        #expect(dropped.undo == .none)

        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: .zero, color: yellow)
        let emptied = try #require(
            [formula].finishingLaTeX(
                formula.id, source: "", fontSize: 16, size: .zero, isNew: false
            ))
        #expect(emptied.annotations.isEmpty)
        #expect(emptied.actionName == "Delete LaTeX")
        #expect(emptied.undo == .toPrevious)  // and ⌘Z brings it back
    }

    @Test func textBoxesFollowTheSameRulesAsFormulas() throws {
        let begun = [Annotation]().beginningTextBox(
            pageIndex: 0, bounds: CGRect(x: 50, y: 600, width: 40, height: 20),
            fontSize: 14, color: blue)
        #expect(begun.edit.undo == .none)
        let added = try #require(
            begun.edit.annotations.finishingTextBox(
                begun.id, text: "Hi", fontSize: 14,
                size: CGSize(width: 30, height: 24), isNew: true))
        #expect(
            added.annotations[0].bounds
                // the centre stays at (70, 610)
                == CGRect(x: 55, y: 598, width: 30, height: 24))
        #expect(added.actionName == "Add Text")
        #expect(added.undo == .to([]))
        #expect(
            added.annotations[0].isMovable
                && added.annotations[0].isRecolorable)

        let box = added.annotations
        #expect(
            box.finishingTextBox(
                begun.id, text: "Hi", fontSize: 14, size: .zero, isNew: false)
                == nil)  // unchanged
        #expect(
            box.finishingTextBox(
                begun.id, text: "Hi", fontSize: 18, size: .zero, isNew: false)?
                .actionName == "Edit Text")
        let emptied = try #require(
            box.finishingTextBox(
                begun.id, text: " \n", fontSize: 14, size: .zero, isNew: false)
        )
        #expect(
            emptied.annotations.isEmpty && emptied.actionName == "Delete Text"
                && emptied.undo == .toPrevious)
        // A formula's id doesn't finish a text box, and the other way round.
        #expect(
            box.finishingLaTeX(
                begun.id, source: "x", fontSize: 14, size: .zero, isNew: false)
                == nil)
    }

    @Test func aGrowingBoxStaysOnItsPage() throws {
        let page = PageFrame(box: CGRect(x: 0, y: 0, width: 612, height: 792))
        let begun = [Annotation]().beginningTextBox(
            pageIndex: 0, bounds: CGRect(x: 600, y: 2, width: 10, height: 20),
            fontSize: 14, color: blue)
        let edit = try #require(
            begun.edit.annotations.finishingTextBox(
                begun.id, text: "Near the corner", fontSize: 14,
                size: CGSize(width: 110, height: 40), isNew: true, within: page
            ))
        #expect(
            edit.annotations[0].bounds
                // moved in only as far as needed
                == CGRect(x: 502, y: 0, width: 110, height: 40))
        let fits = try #require(
            begun.edit.annotations.finishingTextBox(
                begun.id, text: "x", fontSize: 14,
                size: CGSize(width: 10, height: 20), isNew: true, within: page)
        )
        #expect(
            fits.annotations[0].bounds
                // already on the page: unchanged
                == CGRect(x: 600, y: 2, width: 10, height: 20))
    }

    @Test func resizingATextBoxKeepsItsTopLeftCorner() throws {
        let box = Annotation(
            kind: .textBox(text: "A paragraph", fontSize: 14), pageIndex: 0,
            bounds: CGRect(x: 100, y: 500, width: 200, height: 24), color: blue
        )
        let narrower = try #require(
            [box].resizingTextBox(box.id, to: CGSize(width: 80, height: 60)))
        #expect(
            narrower.annotations[0].bounds
                // the top stays at 524
                == CGRect(x: 100, y: 464, width: 80, height: 60))
        #expect(
            narrower.actionName == "Resize Text"
                && narrower.undo == .toPrevious)
        #expect([box].resizingTextBox(box.id, to: box.bounds.size) == nil)
        let page = PageFrame(box: CGRect(x: 0, y: 0, width: 612, height: 792))
        let wide = try #require(
            [box].resizingTextBox(
                box.id, to: CGSize(width: 600, height: 24), within: page))
        // moved in to stay on the page
        #expect(wide.annotations[0].bounds.maxX == 612)
        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: .zero, color: blue)
        #expect(
            [formula].resizingTextBox(
                // only text boxes
                formula.id, to: CGSize(width: 50, height: 50)) == nil)
    }

    @Test func unchangedFormulaIsNoEdit() {
        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: .zero, color: yellow)
        #expect(
            [formula].finishingLaTeX(
                formula.id, source: "x", fontSize: 16, size: .zero,
                isNew: false) == nil)
    }

    @Test func movingANoteMovesItsAnchorsToo() throws {
        let anchor = CGRect(x: 10, y: 10, width: 50, height: 12)
        let note = Annotation(
            kind: .note(text: "a", anchorRects: [anchor]), pageIndex: 0,
            bounds: CGRect(x: 62, y: 10, width: 15, height: 15), color: yellow)
        let edit = try #require(
            [note].movingItem(note.id, by: CGSize(width: 5, height: -3)))
        #expect(edit.annotations[0].bounds.origin == CGPoint(x: 67, y: 7))
        guard case .note(_, let anchors) = edit.annotations[0].kind else {
            throw Failure()
        }
        #expect(anchors == [anchor.offsetBy(dx: 5, dy: -3)])
        #expect([note].movingItem(note.id, by: .zero) == nil)
    }

    @Test func itemsChangeAsAWhole() throws {
        let lines = [
            (pageIndex: 0, rect: CGRect(x: 0, y: 20, width: 50, height: 10)),
            (pageIndex: 0, rect: CGRect(x: 0, y: 8, width: 50, height: 10)),
        ]
        let other = Annotation(
            kind: .underline, pageIndex: 0,
            bounds: CGRect(x: 0, y: 100, width: 10, height: 10), color: yellow)
        let added = [other].addingMarkup(
            .highlight, lines: lines, color: yellow)
        let annotations = try #require(added).annotations
        let item = annotations[1].itemID

        let recoloured = try #require(
            annotations.recoloringItem(item, to: blue))
        #expect(recoloured.annotations.filter { $0.color == blue }.count == 2)
        #expect(recoloured.annotations[0].color == yellow)
        // already that colour
        #expect(recoloured.annotations.recoloringItem(item, to: blue) == nil)

        let deleted = try #require(annotations.deletingItem(item))
        #expect(deleted.annotations == [other])
        #expect(deleted.annotations.deletingItem(item) == nil)
    }

    @Test func clicksFindTheTopmostAnnotation() {
        let below = Annotation(
            kind: .highlight, pageIndex: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 20), color: yellow)
        let above = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: CGRect(x: 40, y: 0, width: 20, height: 20), color: yellow)
        let note = Annotation(
            kind: .note(
                text: "n",
                anchorRects: [CGRect(x: 0, y: 200, width: 80, height: 12)]),
            pageIndex: 0, bounds: CGRect(x: 82, y: 200, width: 15, height: 15),
            color: yellow)
        let all = [below, above, note]
        #expect(
            all.annotation(at: CGPoint(x: 50, y: 10), pageIndex: 0)?.id
                == above.id)
        #expect(
            all.annotation(at: CGPoint(x: 10, y: 10), pageIndex: 0)?.id
                == below.id)
        #expect(
            all.annotation(at: CGPoint(x: 10, y: 205), pageIndex: 0)?.id
                == note.id)  // its text counts
        #expect(all.annotation(at: CGPoint(x: 10, y: 10), pageIndex: 1) == nil)
        #expect(
            all.annotation(
                at: CGPoint(x: 10, y: 10), pageIndex: 0, hitRects: { _ in [] })
                == nil)
    }

    @Test func onlyFormulasMoveAndNotesKeepTheirColour() {
        func annotation(_ kind: Annotation.Kind) -> Annotation {
            Annotation(kind: kind, pageIndex: 0, bounds: .zero, color: yellow)
        }
        #expect(annotation(.latex(source: "x", fontSize: 16)).isMovable)
        #expect(
            !annotation(.highlight).isMovable
                && !annotation(.note(text: "", anchorRects: [])).isMovable)
        #expect(!annotation(.note(text: "", anchorRects: [])).isRecolorable)
        #expect(annotation(.underline).isRecolorable)
    }

    @Test func restoringAVersionIsOneUndoableStep() throws {
        let old = [
            Annotation(
                kind: .highlight, pageIndex: 0, bounds: .zero, color: yellow)
        ]
        let now =
            old + [
                Annotation(
                    kind: .underline, pageIndex: 1, bounds: .zero, color: blue)
            ]
        let edit = try #require(now.restoringVersion(old))
        #expect(edit.annotations == old)
        #expect(edit.actionName == "Restore Version")
        #expect(edit.undo == .toPrevious)
        #expect(now.restoringVersion(now) == nil)  // already that version
    }

    private struct Failure: Error {}

    // MARK: Relinking

    private func onPage(_ index: Int, at rect: CGRect) -> Annotation {
        Annotation(
            kind: .underline, pageIndex: index, bounds: rect,
            color: RGBAColor(red: 1, green: 0, blue: 0))
    }

    private let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let line = CGRect(x: 72, y: 600, width: 100, height: 14)

    @Test func relinkingCopiesAnnotationsAsOneUndoableStep() throws {
        let source = [onPage(0, at: line), onPage(1, at: line)]
        let relinked = try #require(
            [Annotation]().relinking(source, pageBoxes: [letter, letter]))
        #expect(relinked.edit.annotations == source)
        #expect(relinked.leftOut == 0)
        #expect(relinked.edit.undo == .toPrevious)
    }

    @Test func relinkingLeavesOutWhatHasNoPage() throws {
        let kept = onPage(1, at: line)
        let relinked = try #require(
            [Annotation]().relinking(
                [kept, onPage(2, at: line), onPage(-1, at: line)],
                pageBoxes: [letter, letter]))
        #expect(relinked.edit.annotations == [kept])
        #expect(relinked.leftOut == 2)
    }

    @Test func relinkingLeavesOutWhatWouldBeOffThePage() throws {
        let small = CGRect(x: 0, y: 0, width: 150, height: 150)
        let inside = onPage(0, at: CGRect(x: 10, y: 10, width: 50, height: 14))
        let partly = onPage(
            0, at: CGRect(x: 140, y: 10, width: 50, height: 14))
        let relinked = try #require(
            [Annotation]().relinking(
                [inside, partly, onPage(0, at: line)], pageBoxes: [small]))
        #expect(relinked.edit.annotations == [inside, partly])
        #expect(relinked.leftOut == 1)
    }

    @Test func relinkingNothingThatFitsChangesNothing() {
        #expect(
            [Annotation]().relinking(
                [onPage(3, at: line)], pageBoxes: [letter]) == nil)
    }

    // MARK: On rotated pages

    private func frame(_ rotation: Int) -> PageFrame {
        PageFrame(
            box: CGRect(x: 0, y: 0, width: 612, height: 792),
            rotation: rotation)
    }

    /// The size is what's seen on screen: on a sideways page it's stored the
    /// other way round.
    @Test(arguments: [0, 90, 180, 270])
    func aNewFormulaIsCentredAndTheRightWayRound(rotation: Int) throws {
        let page = frame(rotation)
        let centre = CGPoint(x: 300, y: 400)
        let begun = [Annotation]().beginningLaTeX(
            pageIndex: 0,
            bounds: page.box(
                ofShownSize: CGSize(width: 60, height: 20), centredAt: centre),
            fontSize: 16, color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            begun.edit.annotations.finishingLaTeX(
                begun.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 200, height: 40), isNew: true,
                within: page))
        let bounds = edit.annotations[0].bounds
        #expect(bounds.midX == centre.x && bounds.midY == centre.y)
        #expect(
            bounds.size == page.turned(CGSize(width: 200, height: 40)))
    }

    /// Editing keeps the corner that's at the top left on screen, whichever
    /// corner of the bounds that is.
    @Test(arguments: [0, 90, 180, 270])
    func anEditedFormulaKeepsItsTopLeftCornerOnScreen(rotation: Int) throws {
        let page = frame(rotation)
        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: page.onPage(
                CGRect(x: 100, y: 200, width: 60, height: 20)),
            color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            [formula].finishingLaTeX(
                formula.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 90, height: 50), isNew: false,
                within: page))
        #expect(
            page.shown(edit.annotations[0].bounds)
                == CGRect(x: 100, y: 170, width: 90, height: 50))
    }

    @Test(arguments: [0, 90, 180, 270])
    func aResizedTextBoxKeepsItsTopLeftCornerOnScreen(rotation: Int) throws {
        let page = frame(rotation)
        let box = Annotation(
            kind: .textBox(text: "words", fontSize: 14), pageIndex: 0,
            bounds: page.onPage(
                CGRect(x: 100, y: 200, width: 60, height: 20)),
            color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            [box].resizingTextBox(
                box.id, to: CGSize(width: 120, height: 40), within: page))
        #expect(
            page.shown(edit.annotations[0].bounds)
                == CGRect(x: 100, y: 180, width: 120, height: 40))
        #expect(
            [box].resizingTextBox(
                box.id, to: CGSize(width: 60, height: 20), within: page)
                == nil)
    }

    /// The page's limits are those of the page as shown.
    @Test(arguments: [90, 270])
    func aSidewaysPageKeepsAWideBoxOnIt(rotation: Int) throws {
        let page = frame(rotation)
        let formula = Annotation(
            kind: .latex(source: "x", fontSize: 16), pageIndex: 0,
            bounds: page.onPage(
                CGRect(x: 700, y: 100, width: 60, height: 20)),
            color: .init(red: 0, green: 0, blue: 0))
        let edit = try #require(
            [formula].finishingLaTeX(
                formula.id, source: "x^2", fontSize: 16,
                size: CGSize(width: 200, height: 20), isNew: false,
                within: page))
        // 792 wide on screen, not 612
        #expect(page.shown(edit.annotations[0].bounds).maxX == 792)
    }
}
