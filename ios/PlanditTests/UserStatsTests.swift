import XCTest
@testable import Plandit

final class UserStatsTests: XCTestCase {
    private let calendar = Calendar.current

    private func weeksAgo(_ weeks: Int, from now: Date) -> Date {
        calendar.date(byAdding: .weekOfYear, value: -weeks, to: now)!
    }

    @MainActor private func plan(_ date: Date, cost: Double, budget: Double? = nil, miles: Double? = nil) -> PastPlan {
        PastPlan(title: "Day", date: date, stopCount: 3, cost: cost, budget: budget, walkingMiles: miles)
    }

    @MainActor func testEmptyAccountHasZeroStats() {
        XCTAssertEqual(UserStats.compute(pastPlans: [], visited: []), .empty)
    }

    @MainActor func testStatsComeFromPastPlansAndVisitedPlaces() {
        let now = Date()
        let plans = [
            plan(now, cost: 30, budget: 40, miles: 2.5),
            plan(weeksAgo(1, from: now), cost: 50, budget: 40, miles: 1.5),
            plan(weeksAgo(2, from: now), cost: 10, budget: nil, miles: nil),
        ]
        let visited = [
            SampleData.hungarianPastry, // Morningside Heights
            SampleData.losTacos, // Chelsea
            Place(name: "Absolute Bagels", category: .food, neighborhood: "Morningside Heights", address: "", latitude: 0, longitude: 0),
            Place(name: "Somewhere", category: .food, neighborhood: "", address: "", latitude: 0, longitude: 0),
        ]
        let stats = UserStats.compute(pastPlans: plans, visited: visited, now: now, calendar: calendar)
        XCTAssertEqual(stats.plansCompleted, 3)
        XCTAssertEqual(stats.neighborhoodsVisited, 2)
        XCTAssertEqual(stats.milesWalked, 4.0, accuracy: 0.001)
        XCTAssertEqual(stats.averageSpend, 30, accuracy: 0.001)
        XCTAssertEqual(stats.plansUnderBudget, 1, "a plan without a recorded budget never counts")
        XCTAssertEqual(stats.streakWeeks, 3)
    }

    @MainActor func testStreakMayStartLastWeekButNotEarlier() {
        let now = Date()
        XCTAssertEqual(UserStats.compute(pastPlans: [plan(weeksAgo(1, from: now), cost: 1), plan(weeksAgo(2, from: now), cost: 1)], visited: [], now: now, calendar: calendar).streakWeeks, 2)
        XCTAssertEqual(UserStats.compute(pastPlans: [plan(weeksAgo(2, from: now), cost: 1)], visited: [], now: now, calendar: calendar).streakWeeks, 0)
        XCTAssertEqual(UserStats.compute(pastPlans: [plan(now, cost: 1), plan(weeksAgo(2, from: now), cost: 1)], visited: [], now: now, calendar: calendar).streakWeeks, 1, "a gap breaks the streak")
        XCTAssertEqual(UserStats.compute(pastPlans: [plan(now, cost: 1), plan(now, cost: 2)], visited: [], now: now, calendar: calendar).streakWeeks, 1, "two plans in one week are one week")
    }

    @MainActor func testPastPlanDecodesFilesFromBeforeBudgetAndMilesWereRecorded() throws {
        let json = """
        {"id":"6C8B6B2E-4C7B-4E3E-9E3D-2B6C3F1A2B3C","title":"Sunday in the West Village","date":"2026-10-04T14:00:00Z","stopCount":5,"cost":31}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(PastPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.title, "Sunday in the West Village")
        XCTAssertEqual(plan.cost, 31)
        XCTAssertNil(plan.budget)
        XCTAssertNil(plan.walkingMiles)

        let whole = """
        {"saved":[],"today":{"id":"0A4B0C12-1111-2222-3333-444455556666","date":"2026-11-07T14:00:00Z","title":"Today","budget":60,"stops":[],"legs":[]},"profile":{"name":"A","school":"","homeBase":"","defaultBudget":60,"travelModes":"Walk + subway"},"pastPlans":[\(json)],"visited":[]}
        """
        let snapshot = try SnapshotStore.decode(Data(whole.utf8))
        XCTAssertEqual(snapshot.pastPlans.count, 1)
    }

    @MainActor func testRolloverRecordsBudgetAndWalkingMiles() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let a = PlanStop(place: SampleData.hungarianPastry, start: yesterday, durationMinutes: 60, estimatedCost: 10, status: .done)
        let b = PlanStop(place: SampleData.met, start: yesterday.addingTimeInterval(3600), durationMinutes: 60, estimatedCost: 5, status: .done)
        var plan = DayPlan(date: yesterday, title: "Yesterday", budget: 45, stops: [a, b], legs: [])
        plan.legs = [TravelLeg(fromStopID: a.id, toStopID: b.id, mode: .walk, minutes: 30, miles: 1.4)]
        let store = PlanditStore(today: plan, saved: [], profile: SampleData.profile, pastPlans: [], visited: [], extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil))

        store.rollOverIfNeeded()

        let filed = store.pastPlans.first
        XCTAssertEqual(filed?.budget, 45)
        XCTAssertEqual(filed?.walkingMiles ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(store.stats.plansCompleted, 1)
        XCTAssertEqual(store.stats.plansUnderBudget, 1)
        XCTAssertEqual(store.stats.neighborhoodsVisited, 2)
    }
}
