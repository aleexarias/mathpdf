import MathPDFCore
import Testing

/// Which window edits a PDF's annotations, the others following it.
struct EditingOrderTests {
    final class Window {
        let name: String
        var hash: String?

        init(_ name: String, _ hash: String?) {
            self.name = name
            self.hash = hash
        }
    }

    /// Each window's name with the name of the one it follows, "" for one
    /// that edits.
    private func roles(_ order: EditingOrder<Window>) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: order.assignments(hash: \.hash).map {
                ($0.window.name, $0.editor?.name ?? "")
            })
    }

    @Test func theFirstOpenedEditsAndTheOthersFollowIt() {
        var order = EditingOrder<Window>()
        let first = Window("first", "a")
        let second = Window("second", "a")
        let other = Window("other", "b")
        for window in [first, second, other] { order.add(window) }
        #expect(
            roles(order) == ["first": "", "second": "first", "other": ""])
    }

    @Test func closingTheEditorHandsOverInOpeningOrder() {
        var order = EditingOrder<Window>()
        let windows = ["first", "second", "third"].map { Window($0, "a") }
        for window in windows { order.add(window) }
        order.remove(windows[0])
        #expect(roles(order) == ["second": "", "third": "second"])
    }

    @Test func aWindowThatChangesPagesGoesOnEditing() {
        var order = EditingOrder<Window>()
        let first = Window("first", "a")
        let second = Window("second", "a")
        order.add(first)
        order.add(second)
        // second changes pages, then first arrives at the same pages
        second.hash = "b"
        order.moveToFront(second)
        first.hash = "b"
        #expect(roles(order) == ["second": "", "first": "second"])
    }

    @Test func aWindowNotYetLoadedNeitherEditsNorIsFollowed() {
        var order = EditingOrder<Window>()
        let loading = Window("loading", nil)
        let loaded = Window("loaded", "a")
        order.add(loading)
        order.add(loaded)
        order.add(loaded)
        #expect(roles(order) == ["loaded": ""])
        #expect(order.windows.count == 2)
    }

    /// Thousands of random openings, loads, page changes and closings. After
    /// each, every PDF has exactly one editor, the earliest window showing
    /// it, and every other window showing it follows that one.
    @Test func neverMoreThanOneEditorPerPDF() {
        var random = DiskHeavyTests.PageStressTests.SplitMix64(state: 7)
        let hashes = ["a", "b", "c"]
        var order = EditingOrder<Window>()
        var lastChanger: Window?
        var opened = 0
        for _ in 0..<5000 {
            let windows = order.windows
            switch Int.random(in: 0..<4, using: &random) {
            case 0 where windows.count < 8:
                opened += 1
                let hash =
                    Bool.random(using: &random)
                    ? hashes.randomElement(using: &random) : nil
                order.add(Window("\(opened)", hash))
            case 1:
                if let waiting = windows.filter({ $0.hash == nil })
                    .randomElement(using: &random)
                {
                    waiting.hash = hashes.randomElement(using: &random)
                }
            case 2:
                if let changer = windows.filter({ $0.hash != nil })
                    .randomElement(using: &random)
                {
                    changer.hash = hashes.randomElement(using: &random)
                    order.moveToFront(changer)
                    lastChanger = changer
                }
            default:
                if let closing = windows.randomElement(using: &random) {
                    order.remove(closing)
                }
            }

            let assignments = order.assignments(hash: \.hash)
            var editors: [String: Window] = [:]
            for (window, editor) in assignments {
                let hash = window.hash!
                if let editor {
                    #expect(editor === editors[hash])
                    #expect(editor.hash == hash)
                } else {
                    #expect(editors[hash] == nil)
                    editors[hash] = window
                }
            }
            for (hash, editor) in editors {
                #expect(
                    order.windows.first { $0.hash == hash } === editor)
            }
            if let lastChanger, order.windows.first === lastChanger {
                #expect(assignments.first?.editor == nil)
            }
            #expect(
                assignments.count
                    == order.windows.filter { $0.hash != nil }.count)
        }
    }
}
