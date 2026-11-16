import MathPDFCore
import Testing

struct PageStepTests {
    @Test func onePagePerSpreadStepsByOne() {
        #expect(
            PageStep.target(from: 3, by: 1, pagesPerSpread: 1, pageCount: 10)
                == 4)
        #expect(
            PageStep.target(from: 3, by: -1, pagesPerSpread: 1, pageCount: 10)
                == 2)
    }

    @Test(arguments: [(0, 1, 2), (3, 1, 4), (3, -1, 0), (5, -1, 2)])
    func spreadsStepToTheFirstPageOfTheNext(
        from: Int, by: Int, to: Int
    ) {
        #expect(
            PageStep.target(
                from: from, by: by, pagesPerSpread: 2, pageCount: 10) == to)
    }

    @Test func thereIsNothingPastEitherEnd() {
        #expect(
            PageStep.target(from: 4, by: 1, pagesPerSpread: 2, pageCount: 5)
                == nil)
        #expect(
            PageStep.target(from: 1, by: -1, pagesPerSpread: 2, pageCount: 5)
                == nil)
        #expect(
            PageStep.target(from: 4, by: 1, pagesPerSpread: 1, pageCount: 5)
                == nil)
    }

    @Test func aLastSpreadOfOnePageCanBeReached() {
        #expect(
            PageStep.target(from: 2, by: 1, pagesPerSpread: 2, pageCount: 5)
                == 4)
    }
}
