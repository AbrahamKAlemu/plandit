import XCTest
@testable import Plandit

final class DayPlannerTests: XCTestCase {
    // Fixed day and time zone so every run plans the same day.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func time(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 22 + dayOffset, hour: hour, minute: minute))!
    }

    @MainActor private func planner(_ travel: TravelPreference = .walkAndTransit, exactSearchLimit: Int = 7) -> DayPlanner {
        DayPlanner(travel: travel, calendar: Self.calendar, exactSearchLimit: exactSearchLimit)
    }

    @MainActor private func candidate(_ place: Place, cost: Double = 0, minutes: Int? = nil) -> PlanCandidate {
        PlanCandidate(place: place, cost: cost, durationMinutes: minutes)
    }

    @MainActor private func place(_ name: String, _ latitude: Double, _ longitude: Double, hours: String? = nil, category: PlaceCategory = .activity) -> Place {
        Place(name: name, category: category, neighborhood: "Test", address: "\(name) St", latitude: latitude, longitude: longitude, hours: hours)
    }

    @MainActor private var samplePlaces: [Place] {
        [SampleData.hungarianPastry, SampleData.met, SampleData.highLine, SampleData.losTacos, SampleData.washingtonSquare,
         SampleData.joesPizza, SampleData.levain, SampleData.littleIsland, SampleData.cloisters, SampleData.smalls,
         SampleData.russAndDaughters, SampleData.tram]
    }

    // MARK: - Basics

    @MainActor func testNoCandidatesPlansNothing() {
        let outcome = planner().plan(.init(candidates: [], start: time(10), budget: 60))
        XCTAssertTrue(outcome.stops.isEmpty)
        XCTAssertTrue(outcome.legs.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    @MainActor func testOneCandidateStartsAtTheStartTime() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.levain, cost: 6)], start: time(10), budget: 60))
        XCTAssertEqual(outcome.stops.count, 1)
        XCTAssertEqual(outcome.stops[0].start, time(10))
        XCTAssertEqual(outcome.stops[0].durationMinutes, PlaceCategory.food.typicalVisitMinutes)
        XCTAssertEqual(outcome.stops[0].status, .upcoming)
        XCTAssertTrue(outcome.legs.isEmpty)
        XCTAssertEqual(outcome.cost, 6)
    }

    @MainActor func testStartTimeRoundsUpToFiveMinutes() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.levain)], start: time(10, 7), budget: 60))
        XCTAssertEqual(outcome.stops.first?.start, time(10, 10))
    }

    @MainActor func testStopKeepsCandidateIdentityAndDetails() {
        let postID = UUID()
        let pick = PlanCandidate(place: SampleData.levain, cost: 6, durationMinutes: 20, sourcePostID: postID, note: "Saved from TikTok.")
        let stop = planner().plan(.init(candidates: [pick], start: time(10), budget: 60)).stops[0]
        XCTAssertEqual(stop.id, pick.id)
        XCTAssertEqual(stop.sourcePostID, postID)
        XCTAssertEqual(stop.durationMinutes, 20)
        XCTAssertEqual(stop.estimatedCost, 6)
        XCTAssertEqual(stop.note, "Saved from TikTok.")
    }

    @MainActor func testSamePlacePickedTwiceBecomesOneStop() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.levain), candidate(SampleData.levain), candidate(SampleData.met)],
                                           start: time(10), budget: 60))
        XCTAssertEqual(outcome.stops.map(\.place.name).sorted(), ["Levain Bakery", "The Met"])
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    // MARK: - Ordering

    @MainActor func testPlacesAlongALineAreVisitedInLineOrder() {
        // North to south along one avenue, picked out of order.
        let north = place("North", 40.80, -73.96), middle = place("Middle", 40.78, -73.97), south = place("South", 40.76, -73.98)
        let outcome = planner().plan(.init(candidates: [candidate(middle), candidate(south), candidate(north)], start: time(10), budget: 60))
        let names = outcome.stops.map(\.place.name)
        XCTAssertTrue(names == ["North", "Middle", "South"] || names == ["South", "Middle", "North"], "got \(names)")
    }

    @MainActor func testOrderBeatsThePickedOrderOnTravel() {
        // Zig-zag uptown/downtown when picked; the planner should not.
        let picks = [SampleData.cloisters, SampleData.joesPizza, SampleData.hungarianPastry, SampleData.losTacos].map { candidate($0) }
        let planned = planner().plan(.init(candidates: picks, start: time(9), budget: 100))
        let asPicked = zip(picks, picks.dropFirst()).reduce(0) { total, pair in
            total + TravelLeg.estimate(from: pair.0.place, to: pair.1.place, fromStopID: pair.0.id, toStopID: pair.1.id, travel: .walkAndTransit).minutes
        }
        XCTAssertLessThan(planned.travelMinutes, asPicked)
        XCTAssertEqual(planned.stops.count, 4)
    }

    @MainActor func testFastSearchMatchesExactSearch() {
        // No hours and no evening-only places, so only travel matters; compare the heuristic to trying every order.
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<12 {
            let places = samplePlaces.filter { $0.category != .nightlife }.map { var p = $0; p.hours = nil; return p }
                .shuffled(using: &rng).prefix(8)
            let request = DayPlanner.Request(candidates: places.map { candidate($0) }, start: time(9), budget: 500)
            let exact = planner(exactSearchLimit: 8).plan(request)
            let fast = planner(exactSearchLimit: 0).plan(request)
            XCTAssertEqual(exact.stops.count, 8)
            XCTAssertEqual(fast.stops.count, 8)
            XCTAssertLessThanOrEqual(exact.travelMinutes, fast.travelMinutes, "exact search must be optimal")
            XCTAssertLessThanOrEqual(Double(fast.travelMinutes), Double(exact.travelMinutes) * 1.05,
                                     "fast search within 5% of best: \(fast.travelMinutes) vs \(exact.travelMinutes)")
        }
    }

    @MainActor func testPlanningIsDeterministic() {
        let picks = samplePlaces.map { candidate($0, cost: 3) }
        let request = DayPlanner.Request(candidates: picks, start: time(9), budget: 60)
        let first = planner().plan(request), second = planner().plan(request)
        XCTAssertEqual(first.stops.map(\.id), second.stops.map(\.id))
        XCTAssertEqual(first.stops.map(\.start), second.stops.map(\.start))
        XCTAssertEqual(first.skipped.map(\.candidate.id), second.skipped.map(\.candidate.id))
    }

    @MainActor func testTwelvePlacesPlanQuickly() {
        let picks = samplePlaces.map { candidate($0, cost: 2) }
        let started = Date()
        _ = planner().plan(.init(candidates: picks, start: time(8), budget: 200))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the sheet re-plans on every tap")
    }

    // MARK: - Schedule

    @MainActor func testStopsFollowEachOtherWithTravelTimeBetween() {
        let picks = [SampleData.levain, SampleData.met, SampleData.highLine, SampleData.losTacos].map { candidate($0, cost: 5) }
        let outcome = planner().plan(.init(candidates: picks, start: time(10), budget: 60))
        XCTAssertEqual(outcome.legs.count, outcome.stops.count - 1)
        for (index, leg) in outcome.legs.enumerated() {
            let from = outcome.stops[index], to = outcome.stops[index + 1]
            XCTAssertEqual(leg.fromStopID, from.id)
            XCTAssertEqual(leg.toStopID, to.id)
            XCTAssertGreaterThanOrEqual(to.start, from.end.addingTimeInterval(TimeInterval(leg.minutes * 60)))
            XCTAssertLessThan(to.start, from.end.addingTimeInterval(TimeInterval((leg.minutes + 5) * 60)), "no idle gaps")
        }
    }

    // MARK: - Opening hours

    @MainActor func testPlaceThatClosesSoonGoesFirst() {
        // At 3:30 PM the Met (closes 5 PM) has to come before the High Line (open until 10 PM).
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.highLine), candidate(SampleData.met)], start: time(15, 30), budget: 60))
        XCTAssertEqual(outcome.stops.first?.place.name, "The Met")
        let met = outcome.stops[0]
        XCTAssertLessThanOrEqual(met.end, time(17))
        XCTAssertTrue(met.note?.contains("closes at") ?? false)
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    @MainActor func testVisitIsShortenedToEndAtClosing() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.met)], start: time(16), budget: 60))
        XCTAssertEqual(outcome.stops.first?.durationMinutes, 60)
        XCTAssertEqual(outcome.stops.first?.end, time(17))
    }

    @MainActor func testClosedPlaceIsLeftOutWithAReason() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.met), candidate(SampleData.highLine)], start: time(17, 30), budget: 60))
        XCTAssertEqual(outcome.stops.map(\.place.name), ["The High Line"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.closed])
        XCTAssertEqual(outcome.skipped.first?.candidate.place.name, "The Met")
    }

    @MainActor func testTwoPlacesClosingAtTheSameTimeKeepTheOneThatFits() {
        // Both close at 5 PM; from 4:15 PM only one 30-minute visit fits.
        let a = place("Gallery A", 40.7794, -73.9632, hours: "Open until 5 PM")
        let b = place("Gallery B", 40.8649, -73.9319, hours: "Open until 5 PM")
        let outcome = planner().plan(.init(candidates: [candidate(a, minutes: 40), candidate(b, minutes: 40)], start: time(16, 15), budget: 60))
        XCTAssertEqual(outcome.stops.count, 1)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.closed])
        XCTAssertLessThanOrEqual(outcome.stops[0].end, time(17))
    }

    // MARK: - Budget

    @MainActor func testOverBudgetDropsTheMostExpensiveStop() {
        let picks = [candidate(SampleData.joesPizza, cost: 7), candidate(SampleData.losTacos, cost: 15),
                     candidate(SampleData.washingtonSquare, cost: 0), candidate(SampleData.littleIsland, cost: 0)]
        let outcome = planner(.walkOnly).plan(.init(candidates: picks, start: time(12), budget: 10))
        XCTAssertEqual(outcome.skipped.map(\.candidate.place.name), ["Los Tacos No. 1"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.overBudget])
        XCTAssertLessThanOrEqual(outcome.cost, 10)
        XCTAssertEqual(outcome.stops.count, 3)
    }

    @MainActor func testSubwayFaresCountAgainstTheBudget() {
        // Two free places far apart: the $2.90 fare doesn't fit a $0 budget, but walking does.
        let picks = [candidate(SampleData.cloisters, cost: 0), candidate(SampleData.washingtonSquare, cost: 0)]
        let transit = planner(.walkAndTransit).plan(.init(candidates: picks, start: time(10), budget: 0))
        XCTAssertEqual(transit.stops.count, 1)
        XCTAssertEqual(transit.skipped.map(\.reason), [.overBudget])

        let walking = planner(.walkOnly).plan(.init(candidates: picks, start: time(10), budget: 0))
        XCTAssertEqual(walking.stops.count, 2)
        XCTAssertEqual(walking.legs.map(\.mode), [.walk])
        XCTAssertEqual(walking.cost, 0)
    }

    @MainActor func testMoneyAlreadySpentCountsAgainstTheBudget() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.levain, cost: 6)], start: time(10), budget: 20, alreadySpent: 18))
        XCTAssertTrue(outcome.stops.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.overBudget])
    }

    @MainActor func testStopPricierThanTheWholeBudgetIsLeftOut() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.smalls, cost: 25)], start: time(20), budget: 20))
        XCTAssertTrue(outcome.stops.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.overBudget])
    }

    // MARK: - Travel

    @MainActor func testWalkOnlyNeverTakesTransit() {
        let outcome = planner(.walkOnly).plan(.init(candidates: samplePlaces.prefix(6).map { candidate($0) }, start: time(9), budget: 100))
        XCTAssertFalse(outcome.legs.isEmpty)
        XCTAssertTrue(outcome.legs.allSatisfy { $0.mode == .walk && $0.cost == 0 })
    }

    @MainActor func testTravelPreferenceReadsTheProfileSetting() {
        XCTAssertEqual(TravelPreference(setting: "Walk only"), .walkOnly)
        XCTAssertEqual(TravelPreference(setting: "Walk + subway"), .walkAndTransit)
        XCTAssertEqual(TravelPreference(setting: "Walk + subway + bus"), .walkAndTransit)
        for option in UserProfile.travelOptions {
            _ = TravelPreference(setting: option) // every option the profile offers maps to something
        }
    }

    // MARK: - End of day

    @MainActor func testDayThatRunsTooLateLeavesStopsOut() {
        let picks = [SampleData.levain, SampleData.met, SampleData.highLine, SampleData.joesPizza].map { place -> PlanCandidate in
            var open = place
            open.hours = nil
            return candidate(open, minutes: 120)
        }
        let outcome = planner().plan(.init(candidates: picks, start: time(22), budget: 100))
        XCTAssertFalse(outcome.skipped.isEmpty)
        XCTAssertTrue(outcome.skipped.allSatisfy { $0.reason == .outOfTime })
        XCTAssertLessThanOrEqual(outcome.end ?? .distantPast, time(2, dayOffset: 1))
        XCTAssertEqual(outcome.stops.count + outcome.skipped.count, 4)
    }

    @MainActor func testCustomDayEndIsRespected() {
        let picks = [SampleData.washingtonSquare, SampleData.joesPizza, SampleData.littleIsland].map { candidate($0) }
        let outcome = planner().plan(.init(candidates: picks, start: time(12), budget: 60, dayEnd: time(14)))
        XCTAssertLessThanOrEqual(outcome.end ?? .distantPast, time(14))
        XCTAssertTrue(outcome.skipped.allSatisfy { $0.reason == .outOfTime })
    }

    // MARK: - Continuing a day

    @MainActor func testNewStopsFollowTheAnchorStop() {
        let anchor = PlanStop(place: SampleData.met, start: time(11), durationMinutes: 120, estimatedCost: 5, status: .now)
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.levain), candidate(SampleData.highLine)],
                                           start: time(9), budget: 60, anchor: anchor))
        XCTAssertEqual(outcome.legs.count, outcome.stops.count, "includes the leg from the anchor")
        XCTAssertEqual(outcome.legs.first?.fromStopID, anchor.id)
        XCTAssertEqual(outcome.legs.first?.toStopID, outcome.stops.first?.id)
        XCTAssertGreaterThanOrEqual(outcome.stops[0].start, anchor.end)
        // Levain is a short walk from the Met; the High Line is a subway ride.
        XCTAssertEqual(outcome.stops.first?.place.name, "Levain Bakery")
    }

    // MARK: - Evening places

    @MainActor func testNightlifeWaitsForTheEvening() {
        // Picked first, but a jazz club at 5 PM is wrong: it goes after the daytime stops, from 8 PM.
        let picks = [candidate(SampleData.smalls), candidate(SampleData.joesPizza), candidate(SampleData.washingtonSquare)]
        let outcome = planner().plan(.init(candidates: picks, start: time(15), budget: 100))
        XCTAssertEqual(outcome.stops.last?.place.name, "Smalls Jazz Club")
        XCTAssertGreaterThanOrEqual(outcome.stops.last?.start ?? .distantPast, time(20))
        XCTAssertTrue(outcome.stops.last?.note?.contains("evening spot") ?? false)
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    @MainActor func testDaytimeStopsStillMinimizeTravelBeforeAnEveningStop() {
        // Uptown pair, then Chelsea, then the Village jazz club: no zig-zag just because the day waits for 8 PM.
        let picks = [SampleData.tacosPost, SampleData.smallsPost, SampleData.levainPost, SampleData.metPost]
            .map { PlanCandidate(post: $0)! }
        let outcome = planner().plan(.init(candidates: picks, start: time(10), budget: 100))
        let names = outcome.stops.map(\.place.name)
        XCTAssertEqual(Set(names.prefix(2)), ["The Met", "Levain Bakery"], "got \(names)")
        XCTAssertEqual(Array(names.suffix(2)), ["Los Tacos No. 1", "Smalls Jazz Club"])
    }

    @MainActor func testNightlifeAloneStartsAtEightNotAtTheStartTime() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.smalls)], start: time(13), budget: 100))
        XCTAssertEqual(outcome.stops.first?.start, time(20))
    }

    @MainActor func testNightlifeAfterEightStartsRightAway() {
        let outcome = planner().plan(.init(candidates: [candidate(SampleData.smalls)], start: time(21, 30), budget: 100))
        XCTAssertEqual(outcome.stops.first?.start, time(21, 30))
    }

    @MainActor func testNightlifeIsLeftOutWhenTheDayEndsBeforeEvening() {
        let picks = [candidate(SampleData.smalls), candidate(SampleData.levain)]
        let outcome = planner().plan(.init(candidates: picks, start: time(13), budget: 100, dayEnd: time(18)))
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Levain Bakery"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.eveningOnly])
    }

    @MainActor func testWaitingForEveningDoesNotPushDaytimePlacesPastClosing() {
        // The Met closes at 5; with Smalls in the mix the Met must still come first.
        let picks = [candidate(SampleData.smalls), candidate(SampleData.met)]
        let outcome = planner().plan(.init(candidates: picks, start: time(15), budget: 100))
        XCTAssertEqual(outcome.stops.map(\.place.name), ["The Met", "Smalls Jazz Club"])
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    // MARK: - Hours parsing

    @MainActor func testClosingTimesAreReadFromHours() {
        func close(_ hours: String?) -> Date? {
            place("X", 40.7, -73.9, hours: hours).closingTime(on: time(12), calendar: Self.calendar)
        }
        XCTAssertEqual(close("Open until 9 PM"), time(21))
        XCTAssertEqual(close("Open until 5:30 pm"), time(17, 30))
        XCTAssertEqual(close("Open until 11 AM"), time(11))
        XCTAssertEqual(close("Open until noon"), time(12))
        XCTAssertEqual(close("Open until midnight"), time(0, dayOffset: 1))
        XCTAssertEqual(close("Runs until 2 AM"), time(2, dayOffset: 1))
        XCTAssertEqual(close("Open until 12 AM"), time(0, dayOffset: 1))
        XCTAssertNil(close("Open late"))
        XCTAssertNil(close("Shows at 7:30 PM"))
        XCTAssertNil(close("Open until 25 PM"))
        XCTAssertNil(close(nil))
    }

    // MARK: - Invariants over many random days

    @MainActor func testRandomDaysAlwaysKeepThePlannersPromises() {
        var rng = SeededGenerator(seed: 2026)
        for round in 0..<300 {
            let count = Int.random(in: 0...9, using: &rng)
            let picks = samplePlaces.shuffled(using: &rng).prefix(count).map {
                candidate($0, cost: Double(Int.random(in: 0...20, using: &rng)), minutes: [nil, 30, 60, 90].randomElement(using: &rng)!)
            }
            let start = time(Int.random(in: 7...21, using: &rng), [0, 5, 20, 45].randomElement(using: &rng)!)
            let budget = Double(Int.random(in: 0...80, using: &rng))
            let travel: TravelPreference = Bool.random(using: &rng) ? .walkOnly : .walkAndTransit
            let outcome = planner(travel).plan(.init(candidates: picks, start: start, budget: budget))
            let label = "round \(round)"

            // Every pick is either planned or explained.
            XCTAssertEqual(Set(outcome.stops.map(\.id)).union(outcome.skipped.map(\.candidate.id)), Set(picks.map(\.id)), label)
            XCTAssertEqual(outcome.stops.count + outcome.skipped.count, picks.count, label)
            // Never over budget.
            XCTAssertLessThanOrEqual(outcome.cost, budget + 0.001, label)
            // Never before the start, never overlapping, never past the end of the day.
            if let first = outcome.stops.first { XCTAssertGreaterThanOrEqual(first.start, start, label) }
            for (a, b) in zip(outcome.stops, outcome.stops.dropFirst()) { XCTAssertGreaterThanOrEqual(b.start, a.end, label) }
            XCTAssertLessThanOrEqual(outcome.end ?? start, time(2, dayOffset: 1), label)
            // Never at a place after it closes, and never at a nightlife spot before 8 PM.
            for stop in outcome.stops {
                if stop.place.category == .nightlife {
                    XCTAssertGreaterThanOrEqual(stop.start, time(20), "\(label): \(stop.place.name)")
                }
                if let close = stop.place.closingTime(on: start, calendar: Self.calendar) {
                    XCTAssertLessThanOrEqual(stop.end, close, "\(label): \(stop.place.name)")
                }
                XCTAssertGreaterThan(stop.durationMinutes, 0, label)
            }
            // Legs connect consecutive stops and follow the travel setting.
            XCTAssertEqual(outcome.legs.count, max(0, outcome.stops.count - 1), label)
            for (index, leg) in outcome.legs.enumerated() {
                XCTAssertEqual(leg.fromStopID, outcome.stops[index].id, label)
                XCTAssertEqual(leg.toStopID, outcome.stops[index + 1].id, label)
                if travel == .walkOnly { XCTAssertEqual(leg.mode, .walk, label) }
            }
        }
    }
}

/// Repeatable randomness for tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
