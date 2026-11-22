import XCTest
@testable import Plandit

/// Suggested plans for the empty Today (docs/features/suggested-plans, SP-1 to SP-9, SP-17, SP-19, SP-20).
final class PlanSuggesterTests: XCTestCase {
    // A fixed day and time zone, so every run plans the same day: Saturday, November 21, 2026.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    @MainActor private func time(_ hour: Int, _ minute: Int = 0, month: Int = 11, day: Int = 21) -> Date {
        Self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @MainActor private func daysBefore(_ days: Int, _ date: Date) -> Date {
        Self.calendar.date(byAdding: .day, value: -days, to: date)!
    }

    @MainActor private func suggester(_ travel: TravelPreference = .walkAndTransit) -> PlanSuggester {
        PlanSuggester(planner: DayPlanner(travel: travel, calendar: Self.calendar))
    }

    /// Chelsea, near Chelsea Market. 0.001° of latitude is about 0.07 miles.
    private static let base = (latitude: 40.7424, longitude: -74.0060)

    @MainActor private func post(
        _ name: String,
        north: Double = 0,
        east: Double = 0,
        category: PlaceCategory = .activity,
        neighborhood: String = "Chelsea",
        hours: String? = nil,
        cost: Double = 0,
        savedDaysAgo: Int = 1,
        caption: String? = nil,
        tags: [String] = [],
        status: ExtractionStatus = .ready,
        hasPlace: Bool = true
    ) -> SavedPost {
        let place = Place(
            name: name, category: category, neighborhood: neighborhood, address: "\(name) St",
            latitude: Self.base.latitude + north, longitude: Self.base.longitude + east, hours: hours
        )
        return SavedPost(
            url: URL(string: "https://www.tiktok.com/@test/video/\(abs(name.hashValue))")!,
            platform: .tiktok, caption: caption, savedAt: daysBefore(savedDaysAgo, time(12)),
            status: status, place: hasPlace ? place : nil, estimatedCost: cost, tags: tags
        )
    }

    @MainActor private func suggest(
        _ posts: [SavedPost],
        excluding: Set<UUID> = [],
        start: Date? = nil,
        budget: Double = 60,
        travel: TravelPreference = .walkAndTransit
    ) -> [PlanSuggestion] {
        let start = start ?? time(14)
        return suggester(travel).suggestions(
            posts: posts, excluding: excluding, start: start, budget: budget, end: start.addingTimeInterval(4 * 3600)
        )
    }

    /// Eight places a block or two apart, free and quick.
    @MainActor private var neighbors: [SavedPost] {
        (0..<8).map { index in
            post("Spot \(index)", north: Double(index % 4) * 0.002, east: Double(index / 4) * 0.002,
                 category: index.isMultiple(of: 2) ? .food : .activity, savedDaysAgo: index + 1)
        }
    }

    // MARK: - SP-1

    @MainActor func testUsesOnlyMappableSaves() {
        let a = post("Alpha", category: .food)
        let b = post("Bravo", north: 0.002)
        let unmapped = post("Charlie", north: 0.001, status: .processing, hasPlace: false)
        let unconfirmed = post("Delta", north: 0.003, status: .needsConfirmation)
        let suggestions = suggest([a, b, unmapped, unconfirmed])
        XCTAssertFalse(suggestions.isEmpty)
        for suggestion in suggestions {
            XCTAssertTrue(Set(suggestion.postIDs).isSubset(of: [a.id, b.id]), "only saved places on the map")
            XCTAssertEqual(suggestion.outcome.stops.map(\.sourcePostID), suggestion.postIDs)
        }
    }

    // MARK: - SP-2

    @MainActor func testGroupSizeBounds() {
        XCTAssertTrue(suggest([post("Alone")]).isEmpty, "one plannable save gives no plan")

        let chelsea = post("Chelsea spot")
        let cloisters = post("Uptown spot", north: 0.1225, east: 0.0741) // about 8 miles north
        XCTAssertTrue(suggest([chelsea, cloisters]).isEmpty, "two saves far apart give no plan")

        let close = post("Next door", north: 0.002)
        let pair = suggest([chelsea, close])
        XCTAssertEqual(pair.count, 1)
        XCTAssertEqual(pair.first?.outcome.stops.count, 2)

        let many = suggest(neighbors)
        XCTAssertFalse(many.isEmpty)
        for suggestion in many {
            XCTAssertTrue((2...4).contains(suggestion.outcome.stops.count), "\(suggestion.outcome.stops.count) stops")
        }
    }

    // MARK: - SP-3

    @MainActor func testRespectsBudget() {
        // Two places about 2 miles apart: a subway ride each way costs a fare.
        let posts = [
            post("Lunch", category: .food, cost: 12),
            post("Gallery", north: 0.002, cost: 10),
            post("Shop", north: 0.004, category: .shopping, cost: 14),
            post("Across town", north: 0.024, cost: 12),
        ]
        let suggestions = suggest(posts, budget: 30)
        XCTAssertFalse(suggestions.isEmpty)
        for suggestion in suggestions {
            XCTAssertLessThanOrEqual(suggestion.outcome.cost, 30.005, "stops plus fares stay on budget")
        }
        XCTAssertTrue(suggest(posts, budget: 0).isEmpty, "a $0 budget with paid places gives no plan")
    }

    // MARK: - SP-4

    @MainActor func testFitsWindow() {
        let posts = [
            post("Museum", category: .culture),
            post("Gallery", north: 0.002, category: .culture),
            post("Park", north: 0.004, category: .outdoors),
            post("Lunch", north: 0.001, east: 0.001, category: .food),
            post("Coffee", north: 0.003, east: 0.001, category: .coffee),
        ]
        let start = time(14)
        let suggestions = suggest(posts, start: start)
        XCTAssertFalse(suggestions.isEmpty)
        for suggestion in suggestions {
            XCTAssertEqual(suggestion.outcome.stops.first?.start, start, "starts at the planner's start time")
            XCTAssertLessThanOrEqual(suggestion.outcome.end!, start.addingTimeInterval(4 * 3600), "ends within 4 hours")
        }
    }

    // MARK: - SP-5

    @MainActor func testSkipsClosed() {
        let earlyClose = post("Closes at three", category: .culture, hours: "Open until 3 PM")
        let open = post("No hours", north: 0.002, category: .food)
        let closed = post("Closed at one", north: 0.001, hours: "Open until 1 PM")
        let suggestions = suggest([earlyClose, open, closed])
        XCTAssertFalse(suggestions.isEmpty)
        for suggestion in suggestions {
            XCTAssertFalse(suggestion.postIDs.contains(closed.id), "a place already closed isn't suggested")
            if let stop = suggestion.outcome.stops.first(where: { $0.sourcePostID == earlyClose.id }) {
                XCTAssertLessThanOrEqual(stop.end, time(15), "not planned past closing")
            }
        }
    }

    // MARK: - SP-6

    @MainActor func testStopsStayClose() {
        // A line of places about half a mile apart: neighbors walk, the ends are a subway ride apart.
        let line = (0..<6).map { post("Stop \($0)", north: Double($0) * 0.0065, category: $0.isMultiple(of: 2) ? .food : .activity) }

        let walking = suggest(line, travel: .walkOnly)
        XCTAssertFalse(walking.isEmpty)
        for leg in walking.flatMap(\.outcome.legs) {
            XCTAssertEqual(leg.mode, .walk, "walk only means walking trips only")
            XCTAssertLessThanOrEqual(leg.miles, PlanSuggester.maxWalkMiles)
        }

        let transit = suggest(line, travel: .walkAndTransit)
        XCTAssertFalse(transit.isEmpty)
        for leg in transit.flatMap(\.outcome.legs) {
            if leg.mode == .walk {
                XCTAssertLessThanOrEqual(leg.miles, PlanSuggester.maxWalkMiles)
            } else {
                XCTAssertTrue(leg.mode.isTransit)
                XCTAssertLessThanOrEqual(leg.miles, PlanSuggester.maxRideMiles, "one subway ride, not a trip across town")
            }
        }

        let here = post("Here")
        let fiveMilesAway = post("Five miles away", north: 0.0725) // 5 miles north on the map
        XCTAssertGreaterThan(TravelLeg.streetMiles(from: here.place!, to: fiveMilesAway.place!), 5)
        XCTAssertTrue(suggest([here, fiveMilesAway]).isEmpty, "places 5 miles apart are never paired")
        XCTAssertTrue(suggest([here, fiveMilesAway], travel: .walkOnly).isEmpty)
    }

    // MARK: - SP-7

    @MainActor func testDistinctStops() {
        let many = (0..<12).map { index in
            post("Place \(index)", north: Double(index % 6) * 0.003, east: Double(index / 6) * 0.003,
                 category: index.isMultiple(of: 3) ? .food : .activity)
        }
        let suggestions = suggest(many)
        XCTAssertGreaterThan(suggestions.count, 1)
        XCTAssertLessThanOrEqual(suggestions.count, 3)
        let all = suggestions.flatMap(\.postIDs)
        XCTAssertEqual(all.count, Set(all).count, "no stop appears in two suggestions")
    }

    @MainActor func testTwoPostsAboutOnePlaceAreNotTwoSuggestions() {
        let first = post("Same place")
        var second = post("Same place")
        second.savedAt = daysBefore(3, time(12))
        let others = [post("Other one", north: 0.002), post("Other two", north: -0.002)]
        let suggestions = suggest([first, second] + others)
        XCTAssertFalse(suggestions.isEmpty)
        let places = suggestions.flatMap(\.outcome.stops).map(\.place.name)
        XCTAssertLessThanOrEqual(places.filter { $0 == "Same place" }.count, 1, "one place is one stop, whichever post it came from")
    }

    // MARK: - SP-8

    @MainActor func testDeterministic() {
        let posts = neighbors + [post("Far one", north: 0.05), post("Far two", north: 0.052, category: .food)]
        let first = suggest(posts)
        XCTAssertFalse(first.isEmpty)
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<5 {
            XCTAssertEqual(suggest(posts.shuffled(using: &generator)), first, "shuffled saves give the same plans in the same order")
        }
        XCTAssertEqual(suggest(posts), first)
    }

    // MARK: - SP-9

    @MainActor func testExcludesToday() {
        let posts = neighbors
        let inToday = posts[0].id
        let checkedOff = posts[1].id
        let suggestions = suggest(posts, excluding: [inToday, checkedOff])
        XCTAssertFalse(suggestions.isEmpty)
        for suggestion in suggestions {
            XCTAssertFalse(suggestion.postIDs.contains(inToday))
            XCTAssertFalse(suggestion.postIDs.contains(checkedOff))
        }
    }

    // MARK: - SP-19

    @MainActor func testSkipsProbablyOver() {
        let nov10 = 11 // saved November 10, eleven days before the 21st
        let over = post("Over pop-up", category: .shopping, savedDaysAgo: nov10, caption: "Pop-up Nov 15–17")
        let stillOn = post("Pop-up until December", north: 0.002, category: .shopping, savedDaysAgo: nov10, caption: "Pop-up until Dec 1")
        let regular = post("Lunch spot", north: 0.001, category: .food)
        let suggestions = suggest([over, stillOn, regular])
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertFalse(suggestions.flatMap(\.postIDs).contains(over.id), "a save that's probably over isn't suggested")
        XCTAssertTrue(suggestions.flatMap(\.postIDs).contains(stillOn.id), "one that runs until a later date still is")

        // It can still be picked in the planner.
        let store = PlanditStore(
            today: .empty(for: time(12), budget: 60), saved: [over, regular], profile: SampleData.profile,
            pastPlans: [], visited: [], storage: nil
        )
        XCTAssertTrue(store.plannablePosts.contains { $0.id == over.id })
        let picked = store.previewPlan(postIDs: [over.id], start: time(14), budget: 60, mode: .replace)
        XCTAssertEqual(picked.stops.map(\.sourcePostID), [over.id])
    }

    // MARK: - SP-20

    @MainActor func testRecency() {
        // Two identical pairs in different neighborhoods, over a mile apart; walking only, so they never mix.
        func pair(_ prefix: String, north: Double, savedDaysAgo: Int) -> [SavedPost] {
            [post("\(prefix) food", north: north, category: .food, neighborhood: prefix, savedDaysAgo: savedDaysAgo),
             post("\(prefix) park", north: north + 0.003, category: .outdoors, neighborhood: prefix, savedDaysAgo: savedDaysAgo)]
        }
        let newer = pair("Newer", north: 0.03, savedDaysAgo: 2)
        let older = pair("Older", north: 0, savedDaysAgo: 30)
        let equal = suggest(older + newer, travel: .walkOnly)
        XCTAssertEqual(equal.map(\.title), ["Newer", "Older"], "between equal plans, newer saves come first")

        // Better in every other way (a mix, newer on average), but one save is 120 days old.
        let stale = [
            post("Stale food", north: 0.06, category: .food, neighborhood: "Stale", savedDaysAgo: 120),
            post("Stale park", north: 0.062, category: .outdoors, neighborhood: "Stale", savedDaysAgo: 1),
        ]
        let plain = [
            post("Plain one", north: 0.09, neighborhood: "Plain", savedDaysAgo: 80),
            post("Plain two", north: 0.092, neighborhood: "Plain", savedDaysAgo: 80),
        ]
        let ranked = suggest(stale + plain, travel: .walkOnly)
        XCTAssertEqual(ranked.map(\.title), ["Plain", "Stale"], "a plan with a save older than 90 days ranks below any without")
    }

    // MARK: - Scoring terms (one test per weight)

    @MainActor private func outcome(_ categories: [PlaceCategory], cost: Double = 0, travelMinutes: Int = 10) -> DayPlanner.Outcome {
        let stops = categories.enumerated().map { index, category in
            PlanStop(place: Place(name: "P\(index)", category: category, neighborhood: "N", address: "A\(index)", latitude: 40.74, longitude: -74.0),
                     start: time(14 + index), durationMinutes: 45, estimatedCost: cost / Double(categories.count), status: .upcoming)
        }
        let legs = zip(stops, stops.dropFirst()).map {
            TravelLeg(fromStopID: $0.id, toStopID: $1.id, mode: .walk, minutes: travelMinutes / max(1, categories.count - 1), miles: 0.3)
        }
        return DayPlanner.Outcome(stops: stops, legs: legs, skipped: [])
    }

    @MainActor private func score(_ outcome: DayPlanner.Outcome, ages: [Int]? = nil, budget: Double = 60) -> PlanSuggester.Score {
        PlanSuggester.score(outcome, ageInDays: ages ?? Array(repeating: 5, count: outcome.stops.count), budget: budget, alreadySpent: 0, id: "x")
    }

    @MainActor func testScoreFavorsThreeStopsOverTwoButNotFourOverThree() {
        XCTAssertLessThan(score(outcome([.activity, .activity], travelMinutes: 0)), score(outcome([.activity, .activity, .activity], travelMinutes: 0)))
        XCTAssertEqual(score(outcome([.activity, .activity, .activity], travelMinutes: 0)).value,
                       score(outcome([.activity, .activity, .activity, .activity], travelMinutes: 0)).value, accuracy: 0.0001)
    }

    @MainActor func testScoreFavorsFoodWithSomethingElse() {
        XCTAssertLessThan(score(outcome([.activity, .outdoors])), score(outcome([.food, .outdoors])))
        XCTAssertLessThan(score(outcome([.food, .food])), score(outcome([.coffee, .culture])))
    }

    @MainActor func testScoreFavorsNewerSaves() {
        XCTAssertLessThan(score(outcome([.food, .activity]), ages: [20, 20]), score(outcome([.food, .activity]), ages: [2, 2]))
        let old = score(outcome([.food, .activity, .outdoors]), ages: [1, 91, 1])
        XCTAssertTrue(old.hasOldSave)
        XCTAssertLessThan(old, score(outcome([.activity, .activity]), ages: [89, 89]))
    }

    @MainActor func testScoreFavorsLessTravel() {
        XCTAssertLessThan(score(outcome([.food, .activity], travelMinutes: 25)), score(outcome([.food, .activity], travelMinutes: 5)))
    }

    @MainActor func testScoreFavorsMoreMoneyLeft() {
        XCTAssertLessThan(score(outcome([.food, .activity], cost: 40)), score(outcome([.food, .activity], cost: 10)))
    }

    @MainActor func testTiesGoToTheLowerID() {
        let plan = outcome([.food, .activity])
        let a = PlanSuggester.score(plan, ageInDays: [1, 1], budget: 60, alreadySpent: 0, id: "A")
        let b = PlanSuggester.score(plan, ageInDays: [1, 1], budget: 60, alreadySpent: 0, id: "B")
        XCTAssertLessThan(b, a, "higher is better, so the lower id sorts as the better one")
    }

    // MARK: - Title

    @MainActor func testTitleNamesWhereTheStopsAre() {
        func stops(_ neighborhoods: [String]) -> [PlanStop] {
            neighborhoods.map {
                PlanStop(place: Place(name: "Joe's Pizza", category: .food, neighborhood: $0, address: "", latitude: 0, longitude: 0),
                         start: time(14), durationMinutes: 30, estimatedCost: 0, status: .upcoming)
            }
        }
        XCTAssertEqual(PlanSuggester.title(for: stops(["Chelsea", "Chelsea"])), "Chelsea")
        XCTAssertEqual(PlanSuggester.title(for: stops(["Chelsea", "Flatiron", "Chelsea"])), "Chelsea and Flatiron")
        XCTAssertEqual(PlanSuggester.title(for: stops(["Chelsea", "Flatiron", "SoHo"])), "Chelsea, Flatiron and SoHo")
        XCTAssertEqual(PlanSuggester.title(for: stops(["", ""])), "Joe's Pizza", "no neighborhood: the first stop's name")
    }

    // MARK: - SP-17

    @MainActor private func threeHundredSaves() -> [SavedPost] {
        var generator = SeededGenerator(seed: 300)
        let categories = PlaceCategory.allCases.filter { $0 != .nightlife }
        return (0..<300).map { index in
            // Spread over Manhattan below 110th Street, in clumps like real saves.
            let north = Double(Int.random(in: 0...60, using: &generator)) * 0.001
            let east = Double(Int.random(in: 0...30, using: &generator)) * 0.001
            let hours = [nil, "Open until 9 PM", "Open until 5 PM", "Open late"][index % 4]
            return post("Save \(index)", north: north, east: east, category: categories[index % categories.count],
                        neighborhood: "Area \(Int(north * 100))", hours: hours, cost: Double(index % 25),
                        savedDaysAgo: index % 120, caption: index.isMultiple(of: 10) ? "Pop-up Nov 1–3" : "Worth the trip")
        }
    }

    @MainActor func testPerformance300() {
        let posts = threeHundredSaves()
        let suggester = suggester()
        let start = time(14)
        let first = suggester.suggestions(posts: posts, excluding: [], start: start, budget: 60, end: start.addingTimeInterval(4 * 3600))
        XCTAssertFalse(first.isEmpty)
        measure {
            _ = suggester.suggestions(posts: posts, excluding: [], start: start, budget: 60, end: start.addingTimeInterval(4 * 3600))
        }
    }
}
