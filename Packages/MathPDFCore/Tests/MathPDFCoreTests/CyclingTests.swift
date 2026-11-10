import MathPDFCore
import Testing

/// Stepping through the colours ⌥⇥ switches between.
struct CyclingTests {
    private let colors = ["yellow", "red", "green"]

    @Test(arguments: [
        ("yellow", false, "red"), ("green", false, "yellow"),
        ("yellow", true, "green"), ("red", true, "yellow"),
        ("blue", false, "yellow"), ("blue", true, "green"),
    ])
    func stepsAndWrapsRound(from: String, backwards: Bool, to: String) {
        #expect(colors.cycling(from: from, backwards: backwards) == to)
    }

    @Test func aSingleOneStaysAndNoneGivesNothing() {
        #expect(["red"].cycling(from: "red", backwards: false) == "red")
        #expect([String]().cycling(from: "red", backwards: true) == nil)
    }
}
