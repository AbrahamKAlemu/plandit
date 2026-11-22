import Foundation

/// Where a new plan starts when nobody has picked a time: the planner (+) and the suggested plans
/// in an empty Today use the same start, so "Change it" lands on the time the card showed.
enum PlanDefaults {
    /// The next quarter hour. Debug builds launched with `-planStart 11:00` start there instead,
    /// so UI tests don't depend on the time of day.
    static func start(now: Date = .now, calendar: Calendar = .current) -> Date {
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: "planStart") {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now) {
                return date
            }
        }
        #endif
        return nextQuarterHour(after: now, calendar: calendar)
    }

    /// 10:07 → 10:15, 10:15 → 10:30: always a little ahead of now.
    static func nextQuarterHour(after date: Date = .now, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let wholeMinute = calendar.date(from: parts) ?? date
        return calendar.date(byAdding: .minute, value: 15 - (parts.minute ?? 0) % 15, to: wholeMinute) ?? date
    }

    /// A suggested plan ends within this long of its start (SP-4).
    static let suggestionLength: TimeInterval = 4 * 3600
}
