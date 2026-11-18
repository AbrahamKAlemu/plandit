import Foundation

/// The time the app plans around. Debug builds launched with `-clock 19:00` use that time today,
/// so UI tests behave the same whenever they run.
enum AppClock {
    static var now: Date {
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: "clock") {
            let parts = value.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: .now) {
                return date
            }
        }
        #endif
        return .now
    }
}
