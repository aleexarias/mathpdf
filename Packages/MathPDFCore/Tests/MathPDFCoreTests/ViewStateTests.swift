import Foundation
import MathPDFCore
import Testing

struct ViewStateTests {
    private func state(page: Int) -> ViewState {
        ViewState(pageIndex: page, fit: .page, scale: 1.25)
    }

    @Test func aFileGetsBackWhatWasRecordedForIt() {
        var states = RecentViewStates()
        states.record(state(page: 3), for: "/a.pdf")
        #expect(states["/a.pdf"] == state(page: 3))
        #expect(states["/b.pdf"] == nil)
    }

    @Test func recordingTheSameAgainChangesNothing() {
        var states = RecentViewStates()
        let first = states.record(state(page: 3), for: "/a.pdf")
        let same = states.record(state(page: 3), for: "/a.pdf")
        let moved = states.record(state(page: 4), for: "/a.pdf")
        #expect([first, same, moved] == [true, false, true])
    }

    @Test func theOldestAreDroppedBeyondTheLimit() {
        var states = RecentViewStates(limit: 2)
        let start = Date(timeIntervalSince1970: 0)
        for (offset, path) in ["/a.pdf", "/b.pdf", "/c.pdf"].enumerated() {
            states.record(
                state(page: offset), for: path,
                at: start.addingTimeInterval(Double(offset)))
        }
        #expect(states["/a.pdf"] == nil)
        #expect(states["/b.pdf"] == state(page: 1))
        #expect(states["/c.pdf"] == state(page: 2))
    }

    @Test func itSurvivesBeingStored() throws {
        var states = RecentViewStates()
        states.record(state(page: 7), for: "/a.pdf")
        states.record(
            ViewState(pageIndex: 0, fit: nil, scale: 2), for: "/b.pdf")
        let stored = try JSONEncoder().encode(states)
        #expect(
            try JSONDecoder().decode(RecentViewStates.self, from: stored)
                == states)
    }

    @Test func damagedDataIsRefusedRatherThanMisread() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RecentViewStates.self, from: Data("{\"entries\":3}".utf8))
        }
    }
}
