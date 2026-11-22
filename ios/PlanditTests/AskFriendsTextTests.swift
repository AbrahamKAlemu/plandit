import XCTest
@testable import Plandit

/// The persona reviews' copy for "Ask friends what works": the share message, the budget line and
/// the default answer deadline.
@MainActor final class AskFriendsTextTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func link(day: String) -> PlanRequestLink {
        PlanRequestLink(slug: "req1", url: URL(string: "https://plandit.app/g/req1")!, day: day, windowStart: "12:00",
                        windowEnd: "20:00", timeZone: TimeZone.current.identifier, answersBy: Date(), placeIDs: [], builtPlanID: nil)
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    func testTheShareMessage() {
        let now = at(11)
        XCTAssertEqual(AskFriendsText.shareMessage(link(day: DayPlan.isoDay(now)), now: now),
                       "What works for you today? Answer here and I'll make the plan.")
        let later = Calendar.current.date(byAdding: .day, value: 2, to: now)!
        let day = later.formatted(.dateTime.weekday(.wide).month(.wide).day())
        XCTAssertEqual(AskFriendsText.shareMessage(link(day: DayPlan.isoDay(later)), now: now),
                       "What works for you on \(day)? Answer here and I'll make the plan.")
    }

    func testTheBudgetLineNeverSaysWhose() {
        let plan = GroupInputs.Plan(start: ClockTime(13), end: ClockTime(17), budget: 20, candidates: [])
        XCTAssertEqual(AskFriendsText.budget(plan), "Budget: $20 each, the lowest anyone gave")
    }

    // The default deadline for today: the earlier of 2 hours from now and the start of the time,
    // but at least 30 minutes from now, and never after the time ends.
    func testTodaysDeadlineIsTheStartWhenThatComesFirst() {
        XCTAssertEqual(PlanRequestDraft.defaultDeadline(now: at(11), isToday: true, windowStart: at(12), windowEnd: at(20)), at(12))
    }

    func testTodaysDeadlineIsTwoHoursAwayWhenTheTimeStartsLater() {
        XCTAssertEqual(PlanRequestDraft.defaultDeadline(now: at(11), isToday: true, windowStart: at(15), windowEnd: at(20)), at(13))
    }

    func testTodaysDeadlineIsAtLeastHalfAnHourAway() {
        XCTAssertEqual(PlanRequestDraft.defaultDeadline(now: at(11, 50), isToday: true, windowStart: at(12), windowEnd: at(20)), at(12, 20))
    }

    func testTodaysDeadlineIsNeverAfterTheTimeEnds() {
        XCTAssertEqual(PlanRequestDraft.defaultDeadline(now: at(19, 30), isToday: true, windowStart: at(18), windowEnd: at(19, 45)), at(19, 45))
    }

    func testALaterDaysDeadlineIsTwoHoursBeforeTheTimeStarts() {
        let start = Calendar.current.date(byAdding: .day, value: 2, to: at(12))!
        let end = Calendar.current.date(byAdding: .day, value: 2, to: at(20))!
        XCTAssertEqual(PlanRequestDraft.defaultDeadline(now: at(11), isToday: false, windowStart: start, windowEnd: end),
                       start.addingTimeInterval(-2 * 3600))
    }
}
