import Foundation

/// Whether a save is probably over: a pop-up whose dates have passed, or a "this weekend" post saved
/// weeks ago (SP-19). Only suggestions use it; such a save can still be planned by hand.
///
/// - A caption that names a date (found on the phone with `NSDataDetector`) is over once the latest
///   such day has ended. A date with no year is the next one on or after the day it was saved.
/// - A caption or tag with a temporary word ("pop-up", "this weekend"…) and no date is suggested for
///   14 days after it was saved.
enum SaveFreshness {
    static let temporaryWords = ["pop-up", "pop up", "popup", "sample sale", "limited time", "this weekend", "last day", "one day only"]
    /// How long a temporary save with no date is suggested.
    static let temporaryDays = 14

    static func isProbablyOver(_ post: SavedPost, now: Date, calendar: Calendar = .current) -> Bool {
        let facts = facts(for: post, calendar: calendar)
        if let lastDay = facts.lastDay {
            guard let ended = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastDay)) else { return false }
            return now >= ended
        }
        if facts.isTemporary {
            guard let ended = calendar.date(byAdding: .day, value: temporaryDays, to: post.savedAt) else { return false }
            return now >= ended
        }
        return false
    }

    /// What the caption and tags say, independent of today's date.
    struct Facts: Equatable {
        /// The latest day the caption names, if any.
        var lastDay: Date?
        var isTemporary: Bool
    }

    private struct Key: Hashable {
        var id: UUID
        var caption: String?
        var tags: [String]
        var savedAt: Date
        var timeZone: TimeZone
    }

    /// Reading dates is the slow part, so it happens once per post and caption.
    private static var cache: [Key: Facts] = [:]

    static func facts(for post: SavedPost, calendar: Calendar = .current) -> Facts {
        let key = Key(id: post.id, caption: post.caption, tags: post.tags, savedAt: post.savedAt, timeZone: calendar.timeZone)
        if let cached = cache[key] { return cached }
        let text = ([post.caption ?? ""] + post.tags).joined(separator: "\n")
        let lowered = text.lowercased()
        let facts = Facts(
            lastDay: post.caption.flatMap { lastDay(in: $0, savedAt: post.savedAt, calendar: calendar) },
            isTemporary: temporaryWords.contains { lowered.contains($0) }
        )
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = facts
        return facts
    }

    // MARK: - Dates in a caption

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The latest day named in `text`. Only real dates count: "Nov 15", "December 1, 2026", "12/5".
    /// Times ("9 PM"), weekdays and words like "this weekend" or "tomorrow" don't: the detector reads
    /// those against today, not against when the post was made.
    static func lastDay(in text: String, savedAt: Date, calendar: Calendar) -> Date? {
        guard let detector else { return nil }
        let string = text as NSString
        let savedDay = calendar.startOfDay(for: savedAt)
        var latest: Date?
        for match in detector.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            guard let detected = match.date else { continue }
            let matched = string.substring(with: match.range)
            guard namesADay(matched) else { continue }

            // The detector reads the date in the phone's time zone.
            var detectorCalendar = calendar
            detectorCalendar.timeZone = match.timeZone ?? .current
            let parts = detectorCalendar.dateComponents([.year, .month, .day], from: detected)
            guard let month = parts.month, let day = parts.day else { continue }

            var resolved: Date?
            if hasYear(matched), let year = parts.year {
                resolved = calendar.date(from: DateComponents(year: year, month: month, day: day))
            } else {
                resolved = nextDate(month: month, day: day, onOrAfter: savedDay, calendar: calendar)
            }
            guard var date = resolved else { continue }

            // "Nov 15–17": the range ends on the 17th.
            let window = string.substring(with: NSRange(location: match.range.location,
                                                        length: min(string.length - match.range.location, match.range.length + 12)))
            if let endDay = rangeEnd(in: window), endDay > day,
               let end = calendar.date(from: DateComponents(year: calendar.component(.year, from: date), month: month, day: endDay)) {
                date = end
            }
            if match.duration > 0 {
                date = max(date, date.addingTimeInterval(match.duration))
            }
            latest = max(latest ?? date, date)
        }
        return latest
    }

    private static func namesADay(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains(where: \.isNumber) else { return false }
        return lowered.firstMatch(of: monthName) != nil || lowered.firstMatch(of: numericDate) != nil
    }

    private static func hasYear(_ text: String) -> Bool {
        text.firstMatch(of: #/\b(19|20)\d{2}\b/#) != nil
            || text.firstMatch(of: #/\d{1,2}/\d{1,2}/\d{2,4}/#) != nil
            || text.firstMatch(of: #/'\d{2}\b/#) != nil
    }

    /// "Nov 15", "December 1", "15th of March".
    private static let monthName = #/\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*\d|\d(?:st|nd|rd|th)?\s+(?:of\s+)?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)/#
    private static let numericDate = #/\b\d{1,2}/\d{1,2}\b/#

    /// "Nov 15–17", "November 15 to 17": the day after the dash, if the date is such a range.
    private static func rangeEnd(in text: String) -> Int? {
        let pattern = #/\b[A-Za-z]{3,9}\.?\s+\d{1,2}(?:st|nd|rd|th)?\s*(?:–|—|-|to|through|thru)\s*(\d{1,2})(?:st|nd|rd|th)?(?![\d:])(?!\s*(?:am|pm|a\.m\.|p\.m\.))/#
            .ignoresCase()
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return Int(match.1)
    }

    /// The first `month`/`day` on or after `start`: this year's, or next year's once it has passed.
    private static func nextDate(month: Int, day: Int, onOrAfter start: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: start)
        for candidate in [year, year + 1] {
            if let date = calendar.date(from: DateComponents(year: candidate, month: month, day: day)), date >= start {
                return date
            }
        }
        return nil
    }
}
