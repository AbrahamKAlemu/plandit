import XCTest
@testable import Plandit

/// Clock times stay clock times on the days the clocks change: "until 9 PM" closes at 9 PM, evening
/// spots wait for 8 PM and the day ends at 2 AM, not an hour off. In New York the clocks go forward
/// on 2026-03-08 and back on 2026-11-01; 2026-11-22 is an ordinary day.
@MainActor final class DaylightSavingTests: XCTestCase {
    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private var calendar: Calendar { Self.newYork }

    private enum Day {
        case clocksGoForward, clocksGoBack, ordinary

        var month: Int { self == .clocksGoForward ? 3 : 11 }
        var day: Int {
            switch self {
            case .clocksGoForward: 8
            case .clocksGoBack: 1
            case .ordinary: 22
            }
        }
    }

    /// `hour:minute` local time on `day`, or on a later day with `dayOffset`.
    private func time(_ day: Day, _ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: day.month, day: day.day + dayOffset, hour: hour, minute: minute))!
    }

    private func place(_ name: String, category: PlaceCategory, hours: String? = nil,
                       latitude: Double = 40.7344, longitude: Double = -74.0027) -> Place {
        Place(name: name, category: category, neighborhood: "Test", address: "\(name) St",
              latitude: latitude, longitude: longitude, hours: hours)
    }

    private var club: Place { place("Night Club", category: .nightlife) }
    private var museum: Place { place("Museum", category: .culture, latitude: 40.7340, longitude: -74.0020) }

    private func plan(on day: Day, _ stops: [PlanStop]) -> DayPlan {
        var plan = DayPlan(date: time(day, 12), title: "Test", budget: 100, stops: stops, legs: [])
        plan.relinkLegs(travel: .walkAndTransit)
        return plan
    }

    // MARK: - 1. Closing times read from hours

    private func checkClosingTimes(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        func close(_ hours: String) -> Date? {
            place("X", category: .activity, hours: hours).closingTime(on: time(day, 12), calendar: calendar)
        }
        XCTAssertEqual(close("Open until 9 PM"), time(day, 21), "9 PM", file: file, line: line)
        XCTAssertEqual(close("Open until 5:30 pm"), time(day, 17, 30), "5:30 PM", file: file, line: line)
        XCTAssertEqual(close("Open until midnight"), time(day, 0, dayOffset: 1), "midnight", file: file, line: line)
        XCTAssertEqual(close("Runs until 2 AM"), time(day, 2, dayOffset: 1), "2 AM the next day", file: file, line: line)
    }

    func testClosingTimesWhenTheClocksGoForward() { checkClosingTimes(.clocksGoForward) }
    func testClosingTimesWhenTheClocksGoBack() { checkClosingTimes(.clocksGoBack) }
    func testClosingTimesOnAnOrdinaryDay() { checkClosingTimes(.ordinary) }

    // MARK: - 2. When an evening-only place opens, for the planner

    private func checkPlannerOpening(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        let planner = DayPlanner(calendar: calendar)
        let opens = planner.opening(of: PlanCandidate(place: club, cost: 0), on: time(day, 12))
        XCTAssertEqual(opens, time(day, 20), "8 PM", file: file, line: line)
    }

    func testPlannerEveningOpeningWhenTheClocksGoForward() { checkPlannerOpening(.clocksGoForward) }
    func testPlannerEveningOpeningWhenTheClocksGoBack() { checkPlannerOpening(.clocksGoBack) }
    func testPlannerEveningOpeningOnAnOrdinaryDay() { checkPlannerOpening(.ordinary) }

    // MARK: - 3. The planner's day ends at 2 AM the next day

    /// From 11 PM, a visit ending at 1:55 AM fits and one ending at 2:05 AM doesn't.
    private func checkDefaultDayEnd(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        let planner = DayPlanner(calendar: calendar)
        func outcome(minutes: Int) -> DayPlanner.Outcome {
            planner.plan(.init(candidates: [PlanCandidate(place: museum, cost: 0, durationMinutes: minutes)],
                               start: time(day, 23), budget: 100))
        }
        let fits = outcome(minutes: 175)
        XCTAssertEqual(fits.stops.count, 1, "ends 1:55 AM, before 2 AM", file: file, line: line)
        XCTAssertEqual(fits.end, time(day, 1, 55, dayOffset: 1), file: file, line: line)
        let tooLate = outcome(minutes: 185)
        XCTAssertEqual(tooLate.stops.count, 0, "ends 2:05 AM, after 2 AM", file: file, line: line)
        XCTAssertEqual(tooLate.skipped.map(\.reason), [.outOfTime], file: file, line: line)
    }

    func testDayEndsAtTwoAMWhenTheClocksGoForward() { checkDefaultDayEnd(.clocksGoForward) }
    func testDayEndsAtTwoAMWhenTheClocksGoBack() { checkDefaultDayEnd(.clocksGoBack) }
    func testDayEndsAtTwoAMOnAnOrdinaryDay() { checkDefaultDayEnd(.ordinary) }

    // MARK: - 4. Changing a stop's time: the evening spot after it still waits for 8 PM

    private func checkShiftedEveningStop(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        let first = PlanStop(place: museum, start: time(day, 17), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        let evening = PlanStop(place: club, start: time(day, 18), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        var edited = plan(on: day, [first, evening])
        edited.setTime(ofStop: first.id, start: time(day, 17), durationMinutes: 75, calendar: calendar)
        XCTAssertEqual(edited.stops.last?.start, time(day, 20), "8 PM", file: file, line: line)
    }

    func testShiftedEveningStopWhenTheClocksGoForward() { checkShiftedEveningStop(.clocksGoForward) }
    func testShiftedEveningStopWhenTheClocksGoBack() { checkShiftedEveningStop(.clocksGoBack) }
    func testShiftedEveningStopOnAnOrdinaryDay() { checkShiftedEveningStop(.ordinary) }

    // MARK: - 5. Reordering: an evening spot moved first still waits for 8 PM

    private func checkReorderedEveningStop(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        let first = PlanStop(place: museum, start: time(day, 17), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        let evening = PlanStop(place: club, start: time(day, 20), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        let reordered = plan(on: day, [first, evening]).reordered([evening.id, first.id], travel: .walkAndTransit, calendar: calendar)
        XCTAssertEqual(reordered.stops.first?.id, evening.id, file: file, line: line)
        XCTAssertEqual(reordered.stops.first?.start, time(day, 20), "8 PM", file: file, line: line)
    }

    func testReorderedEveningStopWhenTheClocksGoForward() { checkReorderedEveningStop(.clocksGoForward) }
    func testReorderedEveningStopWhenTheClocksGoBack() { checkReorderedEveningStop(.clocksGoBack) }
    func testReorderedEveningStopOnAnOrdinaryDay() { checkReorderedEveningStop(.ordinary) }

    // MARK: - 6. Swap options: an evening spot that closes at 9 PM

    /// A club open until 9 PM fits a 30-minute visit at 8 PM but not at 8:45 PM.
    private func checkSwapOptions(_ day: Day, file: StaticString = #filePath, line: UInt = #line) {
        let other = place("Other Club", category: .nightlife, hours: "Open until 9 PM", latitude: 40.7350, longitude: -74.0030)
        let post = SavedPost(url: URL(string: "https://www.tiktok.com/@test/video/\(UUID().uuidString)")!, platform: .tiktok,
                             savedAt: time(day, 9), status: .ready, place: other, estimatedCost: 0)
        for (hour, minute, offered) in [(20, 0, true), (20, 45, false)] {
            let stop = PlanStop(place: club, start: time(day, hour, minute), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
            let picked = SwapOptions.pick(for: stop, saves: [post], plan: plan(on: day, [stop]), calendar: calendar)
            XCTAssertEqual(picked.map(\.id), offered ? [post.id] : [], "a stop at \(hour):\(minute)", file: file, line: line)
        }
    }

    func testSwapOptionsWhenTheClocksGoForward() { checkSwapOptions(.clocksGoForward) }
    func testSwapOptionsWhenTheClocksGoBack() { checkSwapOptions(.clocksGoBack) }
    func testSwapOptionsOnAnOrdinaryDay() { checkSwapOptions(.ordinary) }
}

/// The shared helper behind those clock times.
@MainActor final class WallClockTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func parts(_ date: Date?) -> [Int]? {
        date.map { date in
            let parts = newYork.dateComponents([.month, .day, .hour, .minute], from: date)
            return [parts.month!, parts.day!, parts.hour!, parts.minute!]
        }
    }

    func testMinutesPastADayFallOnTheNextDay() {
        let day = local(3, 8, 15)
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 20 * 60, on: day)), [3, 8, 20, 0])
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 24 * 60, on: day)), [3, 9, 0, 0])
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 26 * 60 + 15, on: day)), [3, 9, 2, 15])
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 50 * 60, on: day)), [3, 10, 2, 0])
    }

    func testATimeTheClocksSkipBecomesTheNextTimeThatExists() {
        // 2:30 AM doesn't happen on 2026-03-08: the clocks go from 2:00 to 3:00.
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 2 * 60 + 30, on: local(3, 8, 12))), [3, 8, 3, 0])
        // "Until 2 AM" on the night before.
        XCTAssertEqual(parts(newYork.date(atClockMinutes: 26 * 60, on: local(3, 7, 12))), [3, 8, 3, 0])
    }

    func testATimeThatHappensTwiceIsTheFirst() throws {
        // 1:30 AM happens twice on 2026-11-01: first in daylight time (UTC-4), then in standard time.
        let date = try XCTUnwrap(newYork.date(atClockMinutes: 90, on: local(11, 1, 12)))
        XCTAssertEqual(parts(date), [11, 1, 1, 30])
        XCTAssertTrue(newYork.timeZone.isDaylightSavingTime(for: date))
        XCTAssertEqual(newYork.timeZone.secondsFromGMT(for: date), -4 * 3600)
    }

    func testAnOrdinaryDayMatchesCountingFromMidnight() {
        let day = local(11, 22, 9)
        let midnight = newYork.startOfDay(for: day)
        for minutes in stride(from: 0, through: 30 * 60, by: 35) {
            XCTAssertEqual(newYork.date(atClockMinutes: minutes, on: day), midnight.addingTimeInterval(TimeInterval(minutes * 60)), "\(minutes)")
        }
    }
}
