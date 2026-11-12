import CoreGraphics
import MathPDFCore
import Testing

struct PageFitTests {
    @Test func theWidthFitNeverAsksForTheHeight() {
        var asked = false
        func height() -> CGFloat {
            asked = true
            return 800
        }
        let scale = PageFit.width.scale(
            width: 600, height: height(),
            in: CGSize(width: 900, height: 400))
        #expect(scale == 1.5)
        #expect(!asked)
    }

    @Test(
        arguments: [
            (CGSize(width: 900, height: 400), 0.5),
            (CGSize(width: 300, height: 4000), 0.5),
            (CGSize(width: 1200, height: 1600), 2),
        ] as [(CGSize, CGFloat)])
    func aWholePageFitsBothWays(area: CGSize, scale: CGFloat) {
        #expect(
            PageFit.page.scale(width: 600, height: 800, in: area) == scale)
    }

    @Test func zoomToFitStartsWithTheWidthThenAlternates() {
        #expect(PageFit.next(after: nil) == .width)
        #expect(PageFit.next(after: .width) == .page)
        #expect(PageFit.next(after: .page) == .width)
    }
}
