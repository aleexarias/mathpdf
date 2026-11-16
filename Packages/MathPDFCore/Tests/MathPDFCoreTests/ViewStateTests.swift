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
            ViewState(
                pageIndex: 0, fit: nil, scale: 2,
                writing: WritingDefaults(
                    color: RGBAColor(
                        red: 27 / 255, green: 54 / 255, blue: 102 / 255),
                    formulaSize: 20, textSize: 12)),
            for: "/b.pdf")
        let stored = try JSONEncoder().encode(states)
        #expect(
            try JSONDecoder().decode(RecentViewStates.self, from: stored)
                == states)
    }

    @Test func theStandardIsBlackAtSixteenAndFourteen() {
        #expect(
            WritingDefaults.standard
                == WritingDefaults(
                    color: RGBAColor(red: 0, green: 0, blue: 0),
                    formulaSize: 16, textSize: 14))
    }

    @Test func anEntryStoredBeforeHasNoWritingDefaults() throws {
        let stored = Data(
            #"""
            {"entries":{"/a.pdf":{"state":{"pageIndex":2,"fit":"width",\#
            "scale":1},"changedAt":0}}}
            """#.utf8)
        let states = try JSONDecoder().decode(
            RecentViewStates.self, from: stored)
        #expect(states["/a.pdf"]?.pageIndex == 2)
        #expect(states["/a.pdf"]?.writing == nil)
    }

    @Test func aChangedColourIsAChange() {
        var states = RecentViewStates()
        var written = ViewState(
            pageIndex: 0, fit: .width, scale: 1, writing: .standard)
        states.record(written, for: "/a.pdf")
        let blue = RGBAColor(red: 27 / 255, green: 54 / 255, blue: 102 / 255)
        written.writing?.color = blue
        let changed = states.record(written, for: "/a.pdf")
        #expect(changed)
        #expect(states["/a.pdf"]?.writing?.color == blue)
    }

    @Test func damagedDataIsRefusedRatherThanMisread() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RecentViewStates.self, from: Data("{\"entries\":3}".utf8))
        }
    }
}
