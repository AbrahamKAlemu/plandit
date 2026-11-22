import XCTest
@testable import Plandit

/// Group plans, mode 2: candidates can carry a priority (how many friends starred the place). When
/// the planner has to leave something out, it leaves out the lowest priority first, and among equal
/// priorities it follows its usual rule. With every priority equal, it plans exactly as before.
final class PlannerPriorityTests: XCTestCase {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    @MainActor private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute))!
    }

    @MainActor private func planner(_ travel: TravelPreference = .walkAndTransit) -> DayPlanner {
        DayPlanner(travel: travel, calendar: Self.calendar)
    }

    @MainActor private func candidate(_ place: Place, cost: Double = 0, minutes: Int? = nil, priority: Int = 0) -> PlanCandidate {
        var candidate = PlanCandidate(place: place, cost: cost, durationMinutes: minutes)
        candidate.priority = priority
        return candidate
    }

    @MainActor private func place(_ name: String, _ latitude: Double, _ longitude: Double) -> Place {
        Place(name: name, category: .activity, neighborhood: "Test", address: "\(name) St", latitude: latitude, longitude: longitude)
    }

    // MARK: - Over budget

    @MainActor func testOverBudgetDropsTheLowestPriorityBeforeThePricierStop() {
        // Without priorities the $15 stop goes (it saves the most); starred, it stays and the $7 one goes.
        let picks = [candidate(SampleData.losTacos, cost: 15, priority: 2), candidate(SampleData.joesPizza, cost: 7, priority: 0)]
        let outcome = planner(.walkOnly).plan(.init(candidates: picks, start: time(12), budget: 16))
        XCTAssertEqual(outcome.skipped.map(\.candidate.place.name), ["Joe's Pizza"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.overBudget])
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Los Tacos No. 1"])
        XCTAssertLessThanOrEqual(outcome.cost, 16)
    }

    @MainActor func testAmongTheLowestPriorityTheUsualRuleStillPicks() {
        // Both unstarred stops have to go before the starred one, the pricier of them first.
        let picks = [candidate(SampleData.levain, cost: 6, priority: 0), candidate(SampleData.losTacos, cost: 15, priority: 3),
                     candidate(SampleData.joesPizza, cost: 7, priority: 0)]
        let outcome = planner(.walkOnly).plan(.init(candidates: picks, start: time(12), budget: 16))
        XCTAssertEqual(outcome.skipped.map(\.candidate.place.name), ["Joe's Pizza", "Levain Bakery"])
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Los Tacos No. 1"])
    }

    @MainActor func testHigherPriorityGoesOnlyWhenNothingLowerIsLeft() {
        let picks = [candidate(SampleData.losTacos, cost: 15, priority: 2), candidate(SampleData.joesPizza, cost: 7, priority: 1)]
        let outcome = planner(.walkOnly).plan(.init(candidates: picks, start: time(12), budget: 5))
        XCTAssertEqual(outcome.skipped.map(\.candidate.place.name), ["Joe's Pizza", "Los Tacos No. 1"])
        XCTAssertTrue(outcome.stops.isEmpty)
    }

    // MARK: - Too late

    @MainActor func testDayThatRunsTooLateDropsTheLowestPriorityFirst() {
        // Three 50-minute stops in a line, 2 hours to fit them. Without priorities the last one
        // picked goes (every choice frees the same time); here the unstarred middle one does.
        let north = place("North", 40.7320, -74.0), middle = place("Middle", 40.7310, -74.0), south = place("South", 40.7300, -74.0)
        let picks = [candidate(middle, minutes: 50, priority: 0), candidate(south, minutes: 50, priority: 1),
                     candidate(north, minutes: 50, priority: 2)]
        let outcome = planner().plan(.init(candidates: picks, start: time(12), budget: 60, dayEnd: time(14)))
        XCTAssertEqual(outcome.skipped.map(\.candidate.place.name), ["Middle"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.outOfTime])
        XCTAssertEqual(Set(outcome.stops.map(\.place.name)), ["North", "South"])
        XCTAssertLessThanOrEqual(outcome.end ?? .distantFuture, time(14))
    }

    // MARK: - Equal priorities change nothing

    @MainActor func testEqualPrioritiesPlanExactlyAsWithout() {
        let places = [SampleData.hungarianPastry, SampleData.met, SampleData.highLine, SampleData.losTacos, SampleData.washingtonSquare,
                      SampleData.joesPizza, SampleData.levain, SampleData.littleIsland, SampleData.cloisters, SampleData.smalls,
                      SampleData.russAndDaughters, SampleData.tram]
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<40 {
            let count = Int.random(in: 1...8, using: &generator)
            let picks = places.shuffled(using: &generator).prefix(count).map { place in
                PlanCandidate(place: place, cost: Double(Int.random(in: 0...25, using: &generator)),
                              durationMinutes: Int.random(in: 30...150, using: &generator))
            }
            let budget = Double(Int.random(in: 0...80, using: &generator))
            let start = time(Int.random(in: 8...21, using: &generator))
            let end: Date? = Bool.random(using: &generator) ? start.addingTimeInterval(TimeInterval(Int.random(in: 2...8, using: &generator) * 3600)) : nil
            let level = Int.random(in: 0...5, using: &generator)
            let leveled = picks.map { pick -> PlanCandidate in
                var pick = pick
                pick.priority = level
                return pick
            }
            let plain = planner().plan(.init(candidates: Array(picks), start: start, budget: budget, dayEnd: end))
            let even = planner().plan(.init(candidates: leveled, start: start, budget: budget, dayEnd: end))
            XCTAssertEqual(even.stops.map(\.id), plain.stops.map(\.id))
            XCTAssertEqual(even.stops.map(\.start), plain.stops.map(\.start))
            XCTAssertEqual(even.skipped.map(\.candidate.id), plain.skipped.map(\.candidate.id))
            XCTAssertEqual(even.skipped.map(\.reason), plain.skipped.map(\.reason))
        }
    }

    @MainActor func testPriorityDefaultsToZero() {
        XCTAssertEqual(PlanCandidate(place: SampleData.levain, cost: 6).priority, 0)
    }
}
