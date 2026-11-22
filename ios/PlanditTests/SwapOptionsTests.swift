import XCTest
@testable import Plandit

/// GV-9: the places friends may pick instead of a stop are only the organizer's own saves, of the
/// same kind, nearby, open then and within budget; the share preview lists them, and they can be
/// turned off.
@MainActor final class SwapOptionsTests: XCTestCase {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date { SampleData.at(hour, minute) }

    private func stop(_ place: Place, at start: Date, cost: Double = 0, status: StopStatus = .upcoming, post: UUID? = nil) -> PlanStop {
        PlanStop(place: place, start: start, durationMinutes: 60, estimatedCost: cost, sourcePostID: post, status: status)
    }

    private func plan(_ stops: [PlanStop], budget: Double = 60) -> DayPlan {
        var plan = DayPlan(date: at(9), title: "Test", budget: budget, stops: stops, legs: [])
        plan.relinkLegs(travel: .walkAndTransit)
        return plan
    }

    private func post(_ place: Place, cost: Double?, status: ExtractionStatus = .ready) -> SavedPost {
        SavedPost(url: URL(string: "https://www.tiktok.com/@test/video/\(UUID().uuidString)")!, platform: .tiktok,
                  savedAt: SampleData.daysAgo(1), status: status, place: place, estimatedCost: cost)
    }

    private let bryantPark = Place(name: "Bryant Park", category: .outdoors, neighborhood: "Midtown", address: "Bryant Park",
                                   latitude: 40.7536, longitude: -73.9832, hours: "Open until 10 PM")
    private let gansevoort = Place(name: "Gansevoort Plaza", category: .outdoors, neighborhood: "Meatpacking", address: "Gansevoort St",
                                   latitude: 40.7397, longitude: -74.0062, hours: nil)

    // MARK: - Picking

    func testOnlySavedPlacesOfTheSameKindNearby() {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let day = plan([highLine])
        let saves = [SampleData.littleIslandPost, SampleData.levainPost, SampleData.cloistersPost, post(bryantPark, cost: 0)]
        let picked = SwapOptions.pick(for: highLine, saves: saves, plan: day)
        // Little Island (outdoors, ~0.7 mi) and Bryant Park (outdoors, ~1.0 mi). Levain is food; the
        // Cloisters are culture and miles away.
        XCTAssertEqual(picked.map(\.place?.name), ["Little Island", "Bryant Park"], "nearest first")
    }

    func testAPlaceFartherThanAMileAndAFifthIsLeftOut() {
        let met = stop(SampleData.met, at: at(11))
        let picked = SwapOptions.pick(for: met, saves: [SampleData.cloistersPost], plan: plan([met]))
        XCTAssertTrue(picked.isEmpty, "the Cloisters are about 6 miles from the Met")
    }

    func testAtMostTwoPerStop() {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let saves = [post(gansevoort, cost: 0), SampleData.littleIslandPost, post(bryantPark, cost: 0)]
        let picked = SwapOptions.pick(for: highLine, saves: saves, plan: plan([highLine]))
        XCTAssertEqual(picked.count, SwapOptions.maxPerStop)
        XCTAssertEqual(picked.map(\.place?.name), ["Little Island", "Gansevoort Plaza"])
    }

    func testAPlaceClosedAtTheStopsTimeIsLeftOut() {
        // Little Island closes at 9 PM: no 30-minute visit from 8:45 PM.
        let late = stop(SampleData.highLine, at: at(20, 45))
        XCTAssertTrue(SwapOptions.pick(for: late, saves: [SampleData.littleIslandPost], plan: plan([late])).isEmpty)
        // Hours that don't say when it closes count as open.
        XCTAssertEqual(SwapOptions.pick(for: late, saves: [post(gansevoort, cost: 0)], plan: plan([late])).count, 1)
    }

    func testAPlaceThatWouldPutThePlanOverBudgetIsLeftOut() {
        let highLine = stop(SampleData.highLine, at: at(13, 20), cost: 0)
        let pricey = post(bryantPark, cost: 30)
        let tight = plan([highLine], budget: 20)
        XCTAssertTrue(SwapOptions.pick(for: highLine, saves: [pricey], plan: tight).isEmpty)
        XCTAssertEqual(SwapOptions.pick(for: highLine, saves: [pricey], plan: plan([highLine], budget: 40)).count, 1)
    }

    func testOnAPlanAlreadyOverBudgetASwapThatCostsNoMoreIsStillOffered() {
        let highLine = stop(SampleData.highLine, at: at(13, 20), cost: 25)
        let over = plan([highLine], budget: 10)
        XCTAssertEqual(SwapOptions.pick(for: highLine, saves: [post(bryantPark, cost: 20)], plan: over).count, 1)
        XCTAssertTrue(SwapOptions.pick(for: highLine, saves: [post(bryantPark, cost: 30)], plan: over).isEmpty)
    }

    func testPlacesAlreadyInThePlanAndUnmappedSavesAreLeftOut() {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let island = stop(SampleData.littleIsland, at: at(15), post: SampleData.littleIslandPost.id)
        let day = plan([highLine, island])
        let unmapped = post(bryantPark, cost: 0, status: .needsConfirmation)
        XCTAssertTrue(SwapOptions.pick(for: highLine, saves: [SampleData.littleIslandPost, unmapped], plan: day).isEmpty)
    }

    func testTheSamePlaceSavedTwiceIsOfferedOnce() {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let again = post(SampleData.littleIsland, cost: 0)
        let picked = SwapOptions.pick(for: highLine, saves: [SampleData.littleIslandPost, again], plan: plan([highLine]))
        XCTAssertEqual(picked.count, 1)
    }

    func testStopsDoneOrUnderwayGetNoSwaps() {
        let done = stop(SampleData.highLine, at: at(9), status: .done)
        let now = stop(SampleData.washingtonSquare, at: at(10, 30), status: .now)
        let options = SwapOptions.all(for: plan([done, now]), saves: [SampleData.littleIslandPost])
        XCTAssertTrue(options.isEmpty)
    }

    // MARK: - The share payload

    func testThePayloadCarriesStopIdsTheDateAndTheAlternates() throws {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let tacos = stop(SampleData.losTacos, at: at(14, 50), cost: 15)
        let day = plan([highLine, tacos])
        let options = SwapOptions.all(for: day, saves: [SampleData.littleIslandPost, SampleData.levainPost])
        let payload = day.sharedPayload(showPrices: true, note: "", alternates: options)

        XCTAssertTrue(payload.answers)
        XCTAssertEqual(payload.date, Self.isoDay(day.date))
        XCTAssertEqual(payload.stops.map(\.id), [highLine.id, tacos.id])
        let alternates = try XCTUnwrap(payload.stops[0].alternates)
        XCTAssertEqual(alternates, [SharedPlanPayload.Alternate(
            id: SampleData.littleIslandPost.id, name: "Little Island", neighborhood: "Hudson River Park", kind: "Outdoors", costText: "Free"
        )])
        XCTAssertNil(payload.stops[1].alternates, "no food save is near Chelsea Market")
    }

    func testTheAlternatesCostFollowsThePricesToggle() throws {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let day = plan([highLine])
        let options = SwapOptions.all(for: day, saves: [post(bryantPark, cost: 6)])
        XCTAssertEqual(day.sharedPayload(showPrices: true, note: "", alternates: options).stops[0].alternates?.first?.costText, "$6")
        XCTAssertEqual(day.sharedPayload(showPrices: false, note: "", alternates: options).stops[0].alternates?.first?.costText, "")
    }

    func testTheAlternatesMatchTheServersFieldNames() throws {
        let highLine = stop(SampleData.highLine, at: at(13, 20))
        let day = plan([highLine])
        let payload = day.sharedPayload(showPrices: true, note: "", alternates: SwapOptions.all(for: day, saves: [SampleData.littleIslandPost]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["answers"] as? Bool, true)
        XCTAssertEqual(json["date"] as? String, Self.isoDay(day.date))
        let stop = try XCTUnwrap((json["stops"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["id"] as? String, highLine.id.uuidString)
        let alternate = try XCTUnwrap((stop["alternates"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(alternate.keys), ["id", "name", "neighborhood", "kind", "costText"])
        XCTAssertEqual(alternate["id"] as? String, SampleData.littleIslandPost.id.uuidString)
    }

    func testWithSwapsOffThePayloadHasNoAlternates() async throws {
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        try await store.shareToday(showPrices: true, note: "", suggestsSwaps: false)
        let last = await sharing.published.last
        let payload = try XCTUnwrap(last)
        XCTAssertTrue(payload.stops.allSatisfy { $0.alternates == nil })
        XCTAssertEqual(payload.stops.map(\.id), store.today.stops.map(\.id), "stop ids still go, for \"I'd swap this\"")
        XCTAssertEqual(store.todayLink?.suggestsSwaps, false)
    }

    func testWithSwapsOnThePreviewAndThePayloadListTheSameAlternates() async throws {
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        let preview = store.swapOptions
        let highLine = try XCTUnwrap(store.today.stops.first { $0.place.name == "The High Line" })
        XCTAssertEqual(preview[highLine.id]?.map(\.id), [SampleData.littleIslandPost.id])

        try await store.shareToday(showPrices: true, note: "")
        let last = await sharing.published.last
        let payload = try XCTUnwrap(last)
        let sent = try XCTUnwrap(payload.stops.first { $0.id == highLine.id })
        XCTAssertEqual(sent.alternates?.map(\.id), [SampleData.littleIslandPost.id])
        XCTAssertEqual(store.todayLink?.suggestsSwaps, true, "on by default")
    }

    func testThePlansDateIsGregorianWhateverThePhonesCalendar() throws {
        // Noon on Nov 22, 2026 in New York: year 2569 in the Buddhist calendar, Reiwa 8 in the
        // Japanese one. The server takes only the Gregorian day.
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = newYork
        let noon = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12)))
        for identifier in [Calendar.Identifier.buddhist, .japanese, .gregorian] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = newYork
            XCTAssertEqual(DayPlan.isoDay(noon, calendar: calendar), "2026-11-22", "\(identifier)")
        }

        // Still the plan's own day: 11 PM in New York is already the 23rd in UTC.
        let lateEvening = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23)))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = newYork
        XCTAssertEqual(DayPlan.isoDay(lateEvening, calendar: buddhist), "2026-11-22")
    }

    func testLongNamesAreCutTheWayTheServerCountsThem() throws {
        // The server counts code points. "👩‍👩‍👧" is one character and five code points; a flag is two.
        let name = String(repeating: "👩‍👩‍👧", count: 30) // 150 code points
        let neighborhood = "Café " + String(repeating: "🇺🇸", count: 50) // 105 code points
        let place = Place(name: name, category: .outdoors, neighborhood: neighborhood, address: "Pier 55",
                          latitude: 40.7420, longitude: -74.0103, hours: nil)
        let alternate = try XCTUnwrap(SharedPlanPayload.Alternate(post: post(place, cost: 0), showPrice: true))
        XCTAssertEqual(alternate.name.unicodeScalars.count, 120)
        XCTAssertEqual(alternate.neighborhood.unicodeScalars.count, 80)
        XCTAssertTrue(name.unicodeScalars.starts(with: alternate.name.unicodeScalars), "cut between code points")
        XCTAssertTrue(neighborhood.unicodeScalars.starts(with: alternate.neighborhood.unicodeScalars))

        let short = Place(name: "Little Island", category: .outdoors, neighborhood: "Hudson River Park", address: "Pier 55",
                          latitude: 40.7420, longitude: -74.0103, hours: nil)
        let untouched = try XCTUnwrap(SharedPlanPayload.Alternate(post: post(short, cost: 0), showPrice: true))
        XCTAssertEqual(untouched.name, "Little Island")
        XCTAssertEqual(untouched.neighborhood, "Hudson River Park")
    }

    // MARK: - Helpers

    private func makeStore(sharing: FakePlanSharing) -> PlanditStore {
        let store = PlanditStore(today: SampleData.dayPlan, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        return store
    }

    private static func isoDay(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }
}
