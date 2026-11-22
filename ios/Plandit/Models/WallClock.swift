import Foundation

nonisolated extension Calendar {
    /// The clock time `minutes` after midnight on `day`: 20 * 60 is 8 PM that day, 26 * 60 is 2 AM the
    /// next day. Set on the day's own clock, not counted from midnight, so 8 PM stays 8 PM on the days
    /// the clocks change. A time the clocks skip (2:30 AM when they go forward) becomes the next time
    /// that exists; a time that happens twice (1:30 AM when they go back) is the first one.
    func date(atClockMinutes minutes: Int, on day: Date) -> Date? {
        let minutesPerDay = 24 * 60
        let days = minutes >= 0 ? minutes / minutesPerDay : (minutes - minutesPerDay + 1) / minutesPerDay
        let clock = minutes - days * minutesPerDay
        guard let target = date(byAdding: .day, value: days, to: startOfDay(for: day)) else { return nil }
        return date(bySettingHour: clock / 60, minute: clock % 60, second: 0, of: target)
    }
}
