import Foundation

/// Where a document's window was left: its page and its zoom.
public struct ViewState: Codable, Equatable, Sendable {
    public var pageIndex: Int
    /// Nil when the zoom was set by hand, to `scale`.
    public var fit: PageFit?
    public var scale: Double

    public init(pageIndex: Int, fit: PageFit?, scale: Double) {
        self.pageIndex = pageIndex
        self.fit = fit
        self.scale = scale
    }
}

/// The view states of the files changed most recently, by path. The oldest
/// are dropped, so it stays small however many PDFs are opened.
public struct RecentViewStates: Codable, Equatable, Sendable {
    private struct Entry: Codable, Equatable, Sendable {
        var state: ViewState
        var changedAt: Date
    }

    private enum CodingKeys: CodingKey {
        case entries
    }

    private var entries: [String: Entry] = [:]
    private var limit = 200

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public subscript(path: String) -> ViewState? {
        entries[path]?.state
    }

    /// Returns whether anything changed.
    @discardableResult
    public mutating func record(
        _ state: ViewState, for path: String, at date: Date = Date()
    ) -> Bool {
        guard entries[path]?.state != state else { return false }
        entries[path] = Entry(state: state, changedAt: date)
        while entries.count > limit,
            let oldest = entries.min(by: {
                $0.value.changedAt < $1.value.changedAt
            })
        {
            entries[oldest.key] = nil
        }
        return true
    }
}
