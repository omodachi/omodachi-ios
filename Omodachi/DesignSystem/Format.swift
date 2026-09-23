import Foundation

/// Numbers, times and durations, in the reader's locale (I18N-1 §2).
///
/// `"\(count)"` is a number written the way C writes it. `Format.count(_:)` is
/// the same number written the way the reader's language writes it — grouped,
/// and in that locale's digits. Nothing in the app interpolates a number into a
/// sentence any more; it asks here first and then hands the string to a catalog
/// accessor.
///
/// Identifiers are the exception and stay as they are: a pixel count in a
/// diagnostic line, a port, a session revision. Those are values, not prose.
enum Format {
    /// A counted thing: seconds left, unread rows, panes.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A whole-number percentage, with the locale's own percent sign and
    /// placement — `70%` in English, `70%` in Chinese, `%70` in Turkish.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Wall-clock time on a notification row.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "2 minutes ago", "2 分钟前" — never a hand-built string.
    static func relative(_ date: Date, to now: Date = Date()) -> String {
        let style = Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide,
                                             locale: .current, calendar: .current)
        return date.formatted(style.locale(.current))
    }

    /// Joins clauses the way the reader's language joins them — "a, b and c"
    /// in English, "a、b、c" in Chinese — rather than with a hard-coded comma.
    static func list(_ parts: [String]) -> String {
        parts.formatted(.list(type: .and, width: .standard))
    }

    /// A build stamp's minute: `yyyymmddHHMM` as the reader's own date.
    static func stamp(_ value: String) -> String? {
        let digits = Array(value)
        guard digits.count == 12, value.allSatisfy(\.isNumber) else { return nil }
        var parts = DateComponents()
        parts.year = Int(String(digits[0...3]))
        parts.month = Int(String(digits[4...5]))
        parts.day = Int(String(digits[6...7]))
        parts.hour = Int(String(digits[8...9]))
        parts.minute = Int(String(digits[10...11]))
        guard let date = Calendar.current.date(from: parts) else { return nil }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}
