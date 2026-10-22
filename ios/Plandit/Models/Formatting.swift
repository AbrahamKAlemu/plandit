import Foundation

extension Double {
    /// "$9", "$2.90", or "Free".
    var dollarsText: String {
        if self == 0 { return "Free" }
        let isWhole = rounded() == self
        return formatted(.currency(code: "USD").precision(.fractionLength(isWhole ? 0 : 2)))
    }

    /// Rounded to whole dollars for totals and budgets: "$42".
    var wholeDollarsText: String {
        formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    var milesText: String { "\(formatted(.number.precision(.fractionLength(1)))) mi" }
}

extension Int {
    /// "45 min", "2 hr", "1 hr 15 min".
    var durationText: String {
        if self < 60 { return "\(self) min" }
        let hours = self / 60, minutes = self % 60
        return minutes == 0 ? "\(hours) hr" : "\(hours) hr \(minutes) min"
    }
}

extension Date {
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
    /// "Sat, Oct 10".
    var shortDay: String { formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    /// "Saturday, October 10".
    var longDay: String { formatted(.dateTime.weekday(.wide).month(.wide).day()) }

    /// "Today", "Yesterday", or "Oct 5".
    var relativeDayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
