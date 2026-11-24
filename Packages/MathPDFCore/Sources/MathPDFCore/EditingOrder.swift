/// The open windows in the order that decides which one edits a PDF's
/// annotations: the first per PDF edits, and the others follow it. Windows
/// are kept in the order they were opened, except that one that changes
/// pages moves to the front, as it has just written the annotations of the
/// PDF it's now showing.
public struct EditingOrder<Window: AnyObject> {
    public private(set) var windows: [Window] = []

    public init() {}

    public mutating func add(_ window: Window) {
        guard !windows.contains(where: { $0 === window }) else { return }
        windows.append(window)
    }

    public mutating func remove(_ window: Window) {
        windows.removeAll { $0 === window }
    }

    public mutating func moveToFront(_ window: Window) {
        remove(window)
        windows.insert(window, at: 0)
    }

    /// Each window showing a PDF, in order, with the window it follows, or
    /// nil for the one that edits that PDF. `hash` is nil for a window that
    /// hasn't loaded its PDF: it's left out.
    public func assignments(hash: (Window) -> String?)
        -> [(window: Window, editor: Window?)]
    {
        var editors: [String: Window] = [:]
        return windows.compactMap { window in
            guard let hash = hash(window) else { return nil }
            let editor = editors[hash]
            if editor == nil { editors[hash] = window }
            return (window, editor)
        }
    }
}
