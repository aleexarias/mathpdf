import CoreGraphics
import Testing

@testable import MathPDFCore

/// Between the page as it's stored and the page as it's seen.
struct PageFrameTests {
    private let box = CGRect(x: 100, y: 200, width: 300, height: 400)

    @Test func aRotationIsAlwaysOneOfTheFour() {
        #expect(PageFrame(box: box, rotation: 360).rotation == 0)
        #expect(PageFrame(box: box, rotation: -90).rotation == 270)
        #expect(PageFrame(box: box, rotation: 450).rotation == 90)
    }

    /// Where the page's own corners end up, turned clockwise: its bottom left
    /// goes to the top left at 90°, and so on.
    @Test(arguments: [
        (0, CGPoint(x: 0, y: 0)), (90, CGPoint(x: 0, y: 300)),
        (180, CGPoint(x: 300, y: 400)), (270, CGPoint(x: 400, y: 0)),
    ])
    func thePagesBottomLeftCorner(rotation: Int, expected: CGPoint) {
        let frame = PageFrame(box: box, rotation: rotation)
        #expect(frame.shown(CGPoint(x: 100, y: 200)) == expected)
    }

    @Test(arguments: [0, 90, 180, 270])
    func pointsAndRectsGoThereAndBack(rotation: Int) {
        let frame = PageFrame(box: box, rotation: rotation)
        let point = CGPoint(x: 130, y: 250)
        #expect(frame.onPage(frame.shown(point)) == point)
        let rect = CGRect(x: 130, y: 250, width: 70, height: 20)
        #expect(frame.onPage(frame.shown(rect)) == rect)
    }

    @Test(arguments: [(0, false), (90, true), (180, false), (270, true)])
    func aSidewaysPageSwapsSizes(rotation: Int, swaps: Bool) {
        let frame = PageFrame(box: box, rotation: rotation)
        let size = CGSize(width: 70, height: 20)
        let swapped = CGSize(width: 20, height: 70)
        #expect(frame.turned(size) == (swaps ? swapped : size))
        #expect(
            frame.shown(CGRect(origin: box.origin, size: size)).size
                == (swaps ? swapped : size))
        #expect(
            frame.shownSize
                == (swaps
                    ? CGSize(width: 400, height: 300)
                    : CGSize(width: 300, height: 400)))
    }

    /// Dragging right on screen is a movement along a different page axis.
    @Test(arguments: [
        (0, CGSize(width: 5, height: 0)), (90, CGSize(width: 0, height: 5)),
        (180, CGSize(width: -5, height: 0)),
        (270, CGSize(width: 0, height: -5)),
    ])
    func aMovementToTheRightOnScreen(rotation: Int, onPage: CGSize) {
        let frame = PageFrame(box: box, rotation: rotation)
        #expect(frame.shown(onPage) == CGSize(width: 5, height: 0))
    }

    /// Each corner, on the page, is where its name says on screen.
    @Test(arguments: [0, 90, 180, 270])
    func cornersAreInTheirOrderOnScreen(rotation: Int) {
        let frame = PageFrame(box: box, rotation: rotation)
        let rect = CGRect(x: 130, y: 250, width: 70, height: 20)
        let corners = frame.shownCorners(of: rect)
        let shown = frame.shown(rect)
        #expect(
            frame.shown(corners.topLeft)
                == CGPoint(x: shown.minX, y: shown.maxY))
        #expect(
            frame.shown(corners.topRight)
                == CGPoint(x: shown.maxX, y: shown.maxY))
        #expect(
            frame.shown(corners.bottomLeft)
                == CGPoint(x: shown.minX, y: shown.minY))
        #expect(
            frame.shown(corners.bottomRight)
                == CGPoint(x: shown.maxX, y: shown.minY))
    }

    @Test(arguments: [0, 90, 180, 270])
    func aNewBoxIsCentredAndTheRightWayRound(rotation: Int) {
        let frame = PageFrame(box: box, rotation: rotation)
        let centre = CGPoint(x: 250, y: 400)
        let placed = frame.box(
            ofShownSize: CGSize(width: 60, height: 20), centredAt: centre)
        #expect(placed.midX == centre.x && placed.midY == centre.y)
        #expect(frame.shown(placed).size == CGSize(width: 60, height: 20))
    }

    @Test(arguments: [0, 90, 180, 270])
    func aNewBoxStaysOnThePage(rotation: Int) {
        let frame = PageFrame(box: box, rotation: rotation)
        let placed = frame.box(
            ofShownSize: CGSize(width: 60, height: 20),
            centredAt: CGPoint(x: 101, y: 201))
        #expect(box.contains(placed))
    }

    /// Only what's above and below the line is left out, whichever way the
    /// line runs on the page.
    @Test(arguments: [0, 90, 180, 270])
    func theMiddleOfALine(rotation: Int) {
        let frame = PageFrame(box: box, rotation: rotation)
        let line = frame.onPage(CGRect(x: 10, y: 100, width: 200, height: 20))
        #expect(
            frame.shown(frame.middleOfLine(line))
                == CGRect(x: 10, y: 106, width: 200, height: 8))
    }
}
