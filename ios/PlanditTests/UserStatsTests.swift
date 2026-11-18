import XCTest
@testable import Plandit

final class UserStatsTests: XCTestCase {
    private let calendar = Calendar.current

    @MainActor private func plan(_ date: Date = .now, cost: Double, budget: Double? = nil, miles: Double? = nil, fares: Double? = nil) -> PastPlan {
        PastPlan(title: "Day", date: date, stopCount: 3, cost: cost, budget: budget, walkingMiles: miles, fares: fares)
    }

    @MainActor func testEmptyAccountHasZeroStats() {
        XCTAssertEqual(UserStats.compute(pastPlans: [], visited: [], placesSaved: 0), .empty)
    }

    @MainActor func testStatsAreCompletedPlansNeighborhoodsAndSavedPlaces() {
        let plans = [plan(cost: 30, budget: 40), plan(cost: 50, budget: 40), plan(cost: 10)]
        let visited = [
            SampleData.hungarianPastry, // Morningside Heights
            SampleData.losTacos, // Chelsea
            Place(name: "Absolute Bagels", category: .food, neighborhood: "Morningside Heights", address: "", latitude: 0, longitude: 0),
            Place(name: "Columbia", category: .culture, neighborhood: " Morningside Heights ", address: "", latitude: 0, longitude: 0),
            Place(name: "Somewhere", category: .food, neighborhood: "", address: "", latitude: 0, longitude: 0),
        ]
        let stats = UserStats.compute(pastPlans: plans, visited: visited, placesSaved: 10)
        XCTAssertEqual(stats, UserStats(plansCompleted: 3, neighborhoodsExplored: 2, placesSaved: 10),
                       "distinct, trimmed, non-empty neighborhoods of visited places")
    }

    @MainActor func testStoreStatsCountSavedPosts() {
        let store = PlanditStore.sample()
        XCTAssertEqual(store.stats.placesSaved, store.saved.count)
        XCTAssertEqual(store.stats.plansCompleted, store.pastPlans.count)
    }

    @MainActor func testPastPlanDecodesFilesFromBeforeBudgetMilesAndFaresWereRecorded() throws {
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
        XCTAssertNil(plan.fares)

        let whole = """
        {"saved":[],"today":{"id":"0A4B0C12-1111-2222-3333-444455556666","date":"2026-11-07T14:00:00Z","title":"Today","budget":60,"stops":[],"legs":[]},"profile":{"name":"A","school":"","homeBase":"","defaultBudget":60,"travelModes":"Walk + subway"},"pastPlans":[\(json)],"visited":[]}
        """
        let snapshot = try SnapshotStore.decode(Data(whole.utf8))
        XCTAssertEqual(snapshot.pastPlans.count, 1)
    }

    @MainActor func testRolloverRecordsBudgetWalkingMilesAndFares() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: .now)!
        let a = PlanStop(place: SampleData.hungarianPastry, start: yesterday, durationMinutes: 60, estimatedCost: 10, status: .done)
        let b = PlanStop(place: SampleData.met, start: yesterday.addingTimeInterval(3600), durationMinutes: 60, estimatedCost: 5, status: .done)
        let c = PlanStop(place: SampleData.losTacos, start: yesterday.addingTimeInterval(7200), durationMinutes: 60, estimatedCost: 15, status: .done)
        var plan = DayPlan(date: yesterday, title: "Yesterday", budget: 45, stops: [a, b, c], legs: [])
        plan.legs = [
            TravelLeg(fromStopID: a.id, toStopID: b.id, mode: .walk, minutes: 30, miles: 1.4),
            TravelLeg(fromStopID: b.id, toStopID: c.id, mode: .subway, minutes: 20, miles: 3, cost: 2.90, detail: "Subway"),
        ]
        let store = PlanditStore(today: plan, saved: [], profile: SampleData.profile, pastPlans: [], visited: [], extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil))

        store.rollOverIfNeeded()

        let filed = store.pastPlans.first
        XCTAssertEqual(filed?.budget, 45)
        XCTAssertEqual(filed?.walkingMiles ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(filed?.fares ?? 0, 2.90, accuracy: 0.001)
        XCTAssertEqual(store.stats.plansCompleted, 1)
        XCTAssertEqual(store.stats.neighborhoodsExplored, 3)
    }

    // MARK: - Past plan rows (PRO-2)

    @MainActor func testPastPlanRowReadsDateStopsAndCostPerPerson() {
        let date = DateComponents(calendar: calendar, year: 2026, month: 11, day: 12, hour: 14).date!
        let row = PastPlan(title: "Sunday in the West Village", date: date, stopCount: 5, cost: 31)
        XCTAssertEqual(row.summaryText, "\(date.shortDay) · 5 stops · $31 per person")
        XCTAssertNil(row.budgetMark, "older plans didn't record a budget")

        let one = PastPlan(title: "Quick one", date: date, stopCount: 1, cost: 0)
        XCTAssertEqual(one.summaryText, "\(date.shortDay) · 1 stop · $0 per person")
    }

    @MainActor func testPastPlanRowSaysWhenFaresAreIncluded() {
        let date = Date.now
        XCTAssertEqual(plan(date, cost: 38, fares: 5.80).summaryText, "\(date.shortDay) · 3 stops · $38 per person, fares included")
        XCTAssertEqual(plan(date, cost: 38, fares: 0).summaryText, "\(date.shortDay) · 3 stops · $38 per person", "no subway or bus that day")
        XCTAssertEqual(plan(date, cost: 38).summaryText, "\(date.shortDay) · 3 stops · $38 per person", "not recorded")
    }

    @MainActor func testPastPlanBudgetMarkSaysHowFarUnderOrOver() {
        XCTAssertEqual(plan(cost: 38, budget: 60).budgetMark, "$22 under")
        XCTAssertEqual(plan(cost: 64.6, budget: 60).budgetMark, "$5 over")
        XCTAssertEqual(plan(cost: 59.8, budget: 60).budgetMark, "On budget")
        XCTAssertEqual(plan(cost: 60, budget: 60).budgetMark, "On budget")
        XCTAssertNil(plan(cost: 38).budgetMark)
    }

    /// The cost is rounded to whole dollars once, and the text, the mark and the color all come
    /// from that one number, so the row never contradicts itself at a half dollar.
    @MainActor func testPastPlanRowAgreesWithItselfAtHalfDollars() {
        let date = Date.now
        let cases: [(cost: Double, shown: String, mark: String, over: Bool)] = [
            (37.50, "$38", "$22 under", false),
            (60.50, "$61", "$1 over", true),
            (59.50, "$60", "On budget", false),
            (60.00, "$60", "On budget", false),
        ]
        for c in cases {
            let row = plan(date, cost: c.cost, budget: 60)
            XCTAssertEqual(row.summaryText, "\(date.shortDay) · 3 stops · \(c.shown) per person", "cost \(c.cost)")
            XCTAssertEqual(row.budgetMark, c.mark, "cost \(c.cost)")
            XCTAssertEqual(row.isOverBudget, c.over, "cost \(c.cost): green only when not over")
        }
        XCTAssertFalse(plan(cost: 80).isOverBudget, "no budget recorded, so never marked over")
    }
}
