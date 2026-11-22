import XCTest
@testable import Plandit

/// Review M4: a time of day stays that time on the days the clocks change.
@MainActor final class ClockTimeTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func hourAndMinute(_ clock: ClockTime, on day: Date) throws -> [Int] {
        let date = try XCTUnwrap(clock.date(on: day, calendar: newYork))
        let parts = newYork.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(newYork.dateComponents([.year, .month, .day], from: day), newYork.dateComponents([.year, .month, .day], from: date),
                       "the same day")
        return [parts.hour!, parts.minute!]
    }

    func testOnePMStaysOnePMWhenTheClocksGoForward() throws {
        XCTAssertEqual(try hourAndMinute(ClockTime(13), on: day(3, 8)), [13, 0])
        XCTAssertEqual(try hourAndMinute(ClockTime(23, 30), on: day(3, 8)), [23, 30])
    }

    func testOnePMStaysOnePMWhenTheClocksGoBack() throws {
        XCTAssertEqual(try hourAndMinute(ClockTime(13), on: day(11, 1)), [13, 0])
        XCTAssertEqual(try hourAndMinute(ClockTime(20), on: day(11, 1)), [20, 0])
    }

    func testAnOrdinaryDayIsUnchanged() throws {
        XCTAssertEqual(try hourAndMinute(ClockTime(13, 30), on: day(11, 22)), [13, 30])
        let date = try XCTUnwrap(ClockTime(13, 30).date(on: day(11, 22), calendar: newYork))
        XCTAssertEqual(ClockTime(of: date, calendar: newYork), ClockTime(13, 30))
    }
}
