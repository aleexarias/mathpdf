import Foundation

/// Timestamps are kept at millisecond precision, so they survive the round
/// trip through the ISO 8601 strings in store files exactly.
public enum Timestamp {
    public static func now() -> Date {
        normalized(Date())
    }

    /// Rounds to the nearest millisecond.
    public static func normalized(_ date: Date) -> Date {
        self.date(milliseconds: milliseconds(date))
    }

    /// `2026-11-03T11:44:02.317Z`, or `20261103T114402.317Z` when `compact`
    /// (for file names).
    public static func string(_ date: Date, compact: Bool = false) -> String {
        let (seconds, millis) = milliseconds(date).quotientAndRemainder(
            dividingBy: 1000)
        let (wholeSeconds, fraction) =
            millis < 0 ? (seconds - 1, millis + 1000) : (seconds, millis)
        let base = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
            .formatted(style(compact: compact))
        // `base` ends in "Z"; put the milliseconds in front of it.
        return base.dropLast() + String(format: ".%03ldZ", Int(fraction))
    }

    public static func parse(_ string: String, compact: Bool = false) -> Date?
    {
        guard string.hasSuffix("Z"), let dot = string.lastIndex(of: ".") else {
            return nil
        }
        let fraction = string[
            string.index(after: dot)..<string.index(before: string.endIndex)]
        guard fraction.count == 3,
            fraction.allSatisfy({ ("0"..."9").contains($0) }),
            let millis = Int64(fraction),
            let base = try? Date(
                String(string[..<dot]) + "Z", strategy: style(compact: compact)
            )
        else { return nil }
        return date(
            milliseconds: Int64(base.timeIntervalSince1970) * 1000 + millis)
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func style(compact: Bool) -> Date.ISO8601FormatStyle {
        compact
            ? Date.ISO8601FormatStyle(
                dateSeparator: .omitted, timeSeparator: .omitted)
            : Date.ISO8601FormatStyle()
    }
}
