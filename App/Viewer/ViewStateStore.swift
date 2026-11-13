import Foundation
import MathPDFCore

/// Where each PDF's window was left, by file path. It's kept in the app's
/// preferences rather than the annotation store: it changes with every
/// scroll, and losing it only costs the place in a document. Writes are held
/// back briefly, so scrolling or zooming through a document is one write.
@MainActor
final class ViewStateStore {
    static let shared = ViewStateStore()

    private static let key = "ViewStates"
    private static let writeDelay = Duration.milliseconds(500)

    private var states: RecentViewStates
    private var pendingWrite: Task<Void, Never>?

    private init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
        states =
            stored.flatMap {
                try? JSONDecoder().decode(RecentViewStates.self, from: $0)
            } ?? RecentViewStates()
    }

    func state(for file: URL) -> ViewState? {
        states[file.path]
    }

    func record(_ state: ViewState, for file: URL) {
        guard states.record(state, for: file.path), pendingWrite == nil
        else { return }
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDelay)
            self?.flush()
        }
    }

    /// Writes what's pending now, for when the app goes to the background or
    /// quits.
    func flush() {
        guard let pendingWrite else { return }
        pendingWrite.cancel()
        self.pendingWrite = nil
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
