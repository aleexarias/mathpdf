public enum PageStep {
    /// The first page of the spread `offset` spreads from the one holding
    /// `index`. Spreads start at multiples of `pagesPerSpread`. Nil past
    /// either end.
    public static func target(
        from index: Int, by offset: Int, pagesPerSpread: Int, pageCount: Int
    ) -> Int? {
        let start = index - index % pagesPerSpread
        let target = start + offset * pagesPerSpread
        return (0..<pageCount).contains(target) ? target : nil
    }
}
