import Foundation

/// Where a document's window was left, its page and its zoom, and what new
/// formulas and text boxes in it start with.
public struct ViewState: Codable, Equatable, Sendable {
    public var pageIndex: Int
    /// Nil when the zoom was set by hand, to `scale`.
    public var fit: PageFit?
    public var scale: Double
    /// Nil in entries stored before it was added.
    public var writing: WritingDefaults?

    public init(
        pageIndex: Int, fit: PageFit?, scale: Double,
        writing: WritingDefaults? = nil
    ) {
        self.pageIndex = pageIndex
        self.fit = fit
        self.scale = scale
        self.writing = writing
    }
}

/// What new formulas and text boxes start with.
public struct WritingDefaults: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var formulaSize: Double
    public var textSize: Double

    public init(color: RGBAColor, formulaSize: Double, textSize: Double) {
        self.color = color
        self.formulaSize = formulaSize
        self.textSize = textSize
    }

    public static let standard = WritingDefaults(
        color: RGBAColor(red: 0, green: 0, blue: 0), formulaSize: 16,
        textSize: 14)
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
