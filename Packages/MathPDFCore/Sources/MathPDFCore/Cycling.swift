extension Array where Element: Equatable {
    /// The element after `element`, or before it going backwards, wrapping
    /// round. One that isn't here goes to the first (or last). Nil if empty.
    public func cycling(from element: Element, backwards: Bool) -> Element? {
        guard let index = firstIndex(of: element) else {
            return backwards ? last : first
        }
        return self[(index + (backwards ? count - 1 : 1)) % count]
    }
}
