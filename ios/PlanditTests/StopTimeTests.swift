import XCTest
@testable import Plandit

/// Changing a stop's time after the plan is made.
/// Sample day: Pastry (done) → Met (now) → High Line → Tacos → Washington Sq → Joe's.
@MainActor final class StopTimeTests: XCTestCase {
    /// The sample day with no overlaps and no slack, so every later stop moves by exactly the change.
    private func cleanDay() -> DayPlan {
        var plan = SampleData.dayPlan
        for index in plan.stops.indices.dropFirst() {
            let previous = plan.stops[index - 1]
            let travel = TimeInterval(plan.leg(after: previous)!.minutes * 60)
            plan.stops[index].start = previous.end.addingTimeInterval(travel)
        }
        return plan
    }

    private func minutes(_ n: Int) -> TimeInterval { TimeInterval(n * 60) }

    func testStartingLaterMovesLaterStopsTheSameAmount() {
        var plan = cleanDay()
        let before = plan.stops
        let highLine = before[2]
        plan.setTime(ofStop: highLine.id, start: highLine.start.addingTimeInterval(minutes(30)), durationMinutes: highLine.durationMinutes)
        XCTAssertEqual(plan.stops[2].start, highLine.start.addingTimeInterval(minutes(30)))
        for index in 3..<before.count {
            XCTAssertEqual(plan.stops[index].start, before[index].start.addingTimeInterval(minutes(30)), "stop \(index + 1)")
        }
        XCTAssertEqual(plan.stops[0].start, before[0].start, "done stops don't move")
        XCTAssertEqual(plan.stops[1].start, before[1].start, "earlier stops don't move")
    }

    func testStayingShorterPullsLaterStopsEarlier() {
        var plan = cleanDay()
        let before = plan.stops
        plan.setTime(ofStop: before[2].id, start: before[2].start, durationMinutes: before[2].durationMinutes - 30)
        XCTAssertEqual(plan.stops[2].durationMinutes, before[2].durationMinutes - 30)
        XCTAssertEqual(plan.stops[3].start, before[3].start.addingTimeInterval(-minutes(30)))
        XCTAssertEqual(plan.stops[5].start, before[5].start.addingTimeInterval(-minutes(30)))
    }

    func testLeavingLaterStopsAloneOnlyMovesThemToAvoidOverlap() {
        var plan = cleanDay()
        let before = plan.stops
        plan.setTime(ofStop: before[2].id, start: before[2].start, durationMinutes: before[2].durationMinutes - 30, moveLaterStops: false)
        XCTAssertEqual(plan.stops[3].start, before[3].start, "a shorter stay leaves a gap instead")

        plan = cleanDay()
        plan.setTime(ofStop: before[2].id, start: before[2].start, durationMinutes: before[2].durationMinutes + 30, moveLaterStops: false)
        XCTAssertEqual(plan.stops[3].start, before[3].start.addingTimeInterval(minutes(30)), "a longer stay still can't overlap the next stop")
    }

    func testCantStartBeforeThePreviousStopAndTheTripThere() {
        var plan = cleanDay()
        let highLine = plan.stops[2]
        let earliest = plan.earliestStart(ofStop: highLine.id)!
        plan.setTime(ofStop: highLine.id, start: earliest.addingTimeInterval(-minutes(60)), durationMinutes: highLine.durationMinutes)
        XCTAssertEqual(plan.stops[2].start, earliest)
    }

    func testAStopUnderwayKeepsItsStartButCanRunLonger() {
        var plan = cleanDay()
        let met = plan.stops[1]
        let nextStart = plan.stops[2].start
        plan.setTime(ofStop: met.id, start: met.start.addingTimeInterval(minutes(45)), durationMinutes: met.durationMinutes + 15)
        XCTAssertEqual(plan.stops[1].start, met.start)
        XCTAssertEqual(plan.stops[1].durationMinutes, met.durationMinutes + 15)
        XCTAssertEqual(plan.stops[2].start, nextStart.addingTimeInterval(minutes(15)))
    }

    func testDoneStopsDontChange() {
        var plan = cleanDay()
        let before = plan.stops
        plan.setTime(ofStop: before[0].id, start: before[0].start.addingTimeInterval(minutes(60)), durationMinutes: 120)
        XCTAssertEqual(plan.stops, before)
    }

    func testStayHasAFloor() {
        var plan = cleanDay()
        plan.setTime(ofStop: plan.stops[2].id, start: plan.stops[2].start, durationMinutes: 0)
        XCTAssertEqual(plan.stops[2].durationMinutes, DayPlan.shortestStay)
    }

    func testTheUsersTimeBeatsTheEveningRuleButLaterNightlifeStillWaits() {
        var plan = cleanDay()
        let calendar = Calendar.current
        let eight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: plan.stops[5].start)!
        // Joe's becomes a jazz club the user wants at 6:30, before the planner's 8 PM rule.
        plan.stops[5].place = SampleData.smalls
        let early = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: plan.stops[5].start)!
        plan.setTime(ofStop: plan.stops[5].id, start: early, durationMinutes: 60)
        XCTAssertEqual(plan.stops[5].start, early)

        // Moving an earlier stop still keeps a nightlife stop it pushes at 8 PM or later.
        plan = cleanDay()
        plan.stops[5].place = SampleData.smalls
        plan.setTime(ofStop: plan.stops[4].id, start: plan.stops[4].start, durationMinutes: plan.stops[4].durationMinutes + 15)
        XCTAssertGreaterThanOrEqual(plan.stops[5].start, eight)
    }

    func testStoreSavesAndPreviewDoesNot() {
        let store = PlanditStore(today: cleanDay(), saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        let stop = store.today.stops[2]
        let later = stop.start.addingTimeInterval(minutes(20))
        let preview = store.previewTime(ofStop: stop.id, start: later, durationMinutes: 90, moveLaterStops: true)
        XCTAssertEqual(preview.stops[2].start, later)
        XCTAssertEqual(store.today.stops[2].start, stop.start, "previewing doesn't change today")

        store.setTime(ofStop: stop.id, start: later, durationMinutes: 90, moveLaterStops: true)
        XCTAssertEqual(store.today.stops[2].start, later)
        XCTAssertEqual(store.today.stops[2].durationMinutes, 90)
    }
}
