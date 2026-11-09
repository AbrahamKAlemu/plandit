import CoreLocation
import XCTest
@testable import Plandit

/// Walk / subway / drive between stops, and budgets the user controls.
final class MapAndBudgetTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    /// Apple Maps stand-in: fixed answers per mode, nil for modes left out.
    @MainActor private final class FakeRoutes: RouteProviding {
        var answers: [TravelMode: RouteInfo]
        private(set) var calls = 0

        init(_ answers: [TravelMode: RouteInfo] = [:]) { self.answers = answers }

        func route(_ mode: TravelMode, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> RouteInfo? {
            calls += 1
            return answers[mode]
        }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "MapAndBudgetTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor private func makeStore(
        plan: DayPlan = SampleData.dayPlan,
        saved: [SavedPost] = SampleData.savedPosts,
        routes: FakeRoutes = FakeRoutes(),
        storage: SnapshotStore? = nil
    ) -> PlanditStore {
        PlanditStore(today: plan, saved: saved, profile: SampleData.profile, pastPlans: [], visited: [],
                     extractor: NoExtractor(), storage: storage, routes: routes)
    }

    /// The sample day with its small overlaps removed (the Met ends 12:45, the subway takes 35 min,
    /// the High Line was at 13:15), so changing one trip moves later stops by exactly the difference.
    @MainActor private func cleanDay() -> DayPlan {
        var plan = SampleData.dayPlan
        for index in plan.stops.indices.dropFirst() {
            let previous = plan.stops[index - 1]
            let travel = TimeInterval(plan.leg(after: previous)!.minutes * 60)
            plan.stops[index].start = max(plan.stops[index].start, previous.end.addingTimeInterval(travel))
        }
        return plan
    }

    /// Sample day: Pastry (done) → Met (now) → High Line → Tacos → Washington Sq → Joe's.
    @MainActor private func legInto(_ index: Int, _ plan: DayPlan) -> TravelLeg {
        plan.legs.first { $0.toStopID == plan.stops[index].id }!
    }

    // MARK: - Travel estimates

    @MainActor func testEstimatesForEachMode() {
        let a = UUID(), b = UUID()
        let walk = TravelLeg.estimate(.walk, miles: 1, fromStopID: a, toStopID: b)
        XCTAssertEqual(walk.minutes, 20)
        XCTAssertEqual(walk.cost, 0)

        let subway = TravelLeg.estimate(.subway, miles: 3, fromStopID: a, toStopID: b)
        XCTAssertEqual(subway.minutes, 22)
        XCTAssertEqual(subway.cost, 2.90)

        let drive = TravelLeg.estimate(.drive, miles: 3, fromStopID: a, toStopID: b)
        XCTAssertEqual(drive.minutes, 20)
        XCTAssertEqual(drive.cost, 15) // $4 + 3 × $3.50, rounded
        XCTAssertEqual(drive.summary, "Drive · 20 min · about $15")

        XCTAssertEqual(TravelLeg.driveFare(miles: 0.5), 10, "short rides still cost the minimum")
    }

    @MainActor func testPlannerNeverPicksDriving() {
        // Driving is always the user's choice; the planner still walks or takes the subway.
        let far = TravelLeg.estimate(from: SampleData.cloisters, to: SampleData.joesPizza, fromStopID: UUID(), toStopID: UUID(), travel: .walkAndTransit)
        XCTAssertEqual(far.mode, .subway)
    }

    // MARK: - Changing a trip moves the day

    @MainActor func testSlowerTripPushesLaterStops() {
        var plan = cleanDay()
        let old = plan.stops
        var leg = legInto(3, plan) // High Line → Tacos, walk 18 min
        leg.mode = .drive
        leg.minutes = 38 // +20
        plan.setLeg(leg)

        XCTAssertEqual(plan.stops[0].start, old[0].start, "done stops never move")
        XCTAssertEqual(plan.stops[1].start, old[1].start, "the current stop never moves")
        XCTAssertEqual(plan.stops[2].start, old[2].start, "stops before the trip stay put")
        for index in 3...5 {
            XCTAssertEqual(plan.stops[index].start, old[index].start.addingTimeInterval(20 * 60), "stop \(index + 1) moves 20 min")
        }
        XCTAssertEqual(plan.legs.first { $0.id == leg.id }?.mode, .drive)
    }

    @MainActor func testFasterTripPullsStopsEarlierButNeverOverlaps() {
        var plan = cleanDay()
        let old = plan.stops
        var leg = legInto(2, plan) // Met → High Line, subway 35 min
        leg.mode = .drive
        leg.minutes = 15 // −20
        plan.setLeg(leg)

        XCTAssertEqual(plan.stops[2].start, old[2].start.addingTimeInterval(-20 * 60))
        for index in 2..<plan.stops.count {
            let previous = plan.stops[index - 1]
            let travel = plan.leg(after: previous)!.minutes
            XCTAssertGreaterThanOrEqual(plan.stops[index].start, previous.end.addingTimeInterval(TimeInterval(travel * 60)))
        }
    }

    @MainActor func testEveningSpotStillStartsAtEight() {
        let pizza = PlanStop(place: SampleData.joesPizza, start: SampleData.at(18), durationMinutes: 45, estimatedCost: 7, status: .upcoming)
        let jazz = PlanStop(place: SampleData.smalls, start: SampleData.at(20), durationMinutes: 90, estimatedCost: 25, status: .upcoming)
        let leg = TravelLeg(fromStopID: pizza.id, toStopID: jazz.id, mode: .walk, minutes: 10, miles: 0.4)
        var plan = DayPlan(date: .now, title: "Tonight", budget: 60, stops: [pizza, jazz], legs: [leg])
        var faster = leg
        faster.mode = .drive
        faster.minutes = 5
        plan.setLeg(faster)
        XCTAssertEqual(plan.stops[1].start, SampleData.at(20), "a faster trip doesn't start the jazz club before 8 PM")
    }

    @MainActor func testArrivingAfterClosingIsFlagged() {
        var plan = SampleData.dayPlan
        XCTAssertTrue(plan.stopsArrivingAfterClose().isEmpty)
        var leg = legInto(3, plan) // into Los Tacos, open until 9 PM
        leg.minutes += 7 * 60
        plan.setLeg(leg)
        XCTAssertEqual(plan.stopsArrivingAfterClose().map(\.place.name).first, "Los Tacos No. 1")
    }

    // MARK: - Store: options, Apple Maps, choosing

    @MainActor func testOptionsAreEstimatesUntilAppleMapsAnswers() async {
        let routes = FakeRoutes([
            .walk: RouteInfo(minutes: 21, miles: 1.0, path: [SampleData.highLine.coordinate, SampleData.losTacos.coordinate]),
            .subway: RouteInfo(minutes: 12, miles: 1.1, path: nil),
            .drive: RouteInfo(minutes: 8, miles: 1.3, path: [SampleData.highLine.coordinate, SampleData.losTacos.coordinate]),
        ])
        let store = makeStore(routes: routes)
        let leg = legInto(3, store.today)

        let before = store.travelOptions(forLeg: leg.id)
        XCTAssertEqual(before.map(\.leg.mode), [.walk, .subway, .drive])
        XCTAssertFalse(before.contains(where: \.isLive))

        await store.loadTravelOptions(forLeg: leg.id)
        let after = store.travelOptions(forLeg: leg.id)
        XCTAssertTrue(after.allSatisfy(\.isLive))
        XCTAssertEqual(after.map(\.leg.minutes), [21, 12, 8 + TravelLeg.pickupMinutes], "driving adds time to get picked up")
        XCTAssertEqual(after[2].leg.cost, TravelLeg.driveFare(miles: 1.3))
        XCTAssertTrue(after.allSatisfy { $0.leg.id == leg.id }, "options keep the leg's id")

        // Asked once per mode; the second load is cached.
        await store.loadTravelOptions(forLeg: leg.id)
        XCTAssertEqual(routes.calls, 3)
    }

    @MainActor func testAppleMapsWithoutTransitFallsBackToTheEstimate() async {
        let store = makeStore(routes: FakeRoutes([.walk: RouteInfo(minutes: 21, miles: 1.0, path: nil)]))
        let leg = legInto(3, store.today)
        await store.loadTravelOptions(forLeg: leg.id)
        let options = store.travelOptions(forLeg: leg.id)
        XCTAssertTrue(options[0].isLive)
        XCTAssertFalse(options[1].isLive)
        XCTAssertEqual(options[1].leg.cost, TravelMode.fare)
    }

    @MainActor func testChoosingDriveUpdatesTheDayAndIsSaved() async throws {
        let storage = SnapshotStore(url: directory.appending(path: "store.json"))
        let store = makeStore(plan: cleanDay(), routes: FakeRoutes([.drive: RouteInfo(minutes: 10, miles: 1.2, path: nil)]), storage: storage)
        let leg = legInto(3, store.today)
        let tacosStart = store.today.stops[3].start
        await store.loadTravelOptions(forLeg: leg.id)
        let drive = try XCTUnwrap(store.travelOptions(forLeg: leg.id).first { $0.leg.mode == .drive })

        store.chooseTravel(drive)
        let chosen = try XCTUnwrap(store.today.legs.first { $0.id == leg.id })
        XCTAssertEqual(chosen.mode, .drive)
        XCTAssertTrue(chosen.isChosen)
        XCTAssertEqual(store.today.stops[3].start, tacosStart.addingTimeInterval(-3 * 60), "18 min walk → 10 min drive + 5 min pickup")
        XCTAssertEqual(store.travelMode(into: store.today.stops[3].id), .drive)
        XCTAssertGreaterThan(store.today.ridesCost, 0)

        store.persistNow()
        let saved = try XCTUnwrap(storage.load())
        XCTAssertEqual(saved.today.legs.first { $0.id == leg.id }?.mode, .drive)
        XCTAssertEqual(saved.today.legs.first { $0.id == leg.id }?.isChosen, true)
    }

    @MainActor func testDrivingLegsGetARealPathOnTheMap() async {
        let path = [SampleData.highLine.coordinate, SampleData.met.coordinate, SampleData.losTacos.coordinate]
        let store = makeStore(routes: FakeRoutes([.drive: RouteInfo(minutes: 10, miles: 1.2, path: path)]))
        let leg = legInto(3, store.today)
        await store.loadTravelOptions(forLeg: leg.id)
        store.chooseTravel(store.travelOptions(forLeg: leg.id)[2])
        await store.loadRoutes()
        XCTAssertEqual(store.path(for: leg).count, 3, "the drive is drawn along streets, not a straight line")
    }

    @MainActor func testRestOfDayOnlyChangesTripsAhead() {
        let store = makeStore()
        let firstLeg = store.today.legs[0] // into the Met: already made
        store.chooseTravelForRestOfDay(.drive)
        XCTAssertEqual(store.today.legs[0], firstLeg, "a trip already made doesn't change")
        XCTAssertTrue(store.today.legs.dropFirst().allSatisfy { $0.mode == .drive })
    }

    @MainActor func testRemovingAStopKeepsOtherChosenTrips() {
        let store = makeStore()
        let leg = legInto(5, store.today) // Washington Sq → Joe's
        store.chooseTravel(store.travelOptions(forLeg: leg.id)[2])
        store.removeStop(store.today.stops[3].id) // Tacos
        XCTAssertEqual(store.today.legs.first { $0.id == leg.id }?.mode, .drive)
    }

    @MainActor func testReplanningKeepsADriveBetweenTheSameStops() {
        // At the Met, with only Joe's left: re-planning can't change the order, so the drive must stay.
        let met = PlanStop(place: SampleData.met, start: SampleData.at(11), durationMinutes: 60, estimatedCost: 5, status: .now)
        let pizza = PlanStop(place: SampleData.joesPizza, start: SampleData.at(13), durationMinutes: 30, estimatedCost: 7, status: .upcoming)
        let plan = DayPlan(date: .now, title: "Today", budget: 60, stops: [met, pizza], legs: [.estimate(from: met, to: pizza)])
        let store = makeStore(plan: plan)
        store.chooseTravel(store.travelOptions(forLeg: plan.legs[0].id)[2])

        store.buildPlan(postIDs: [], start: SampleData.at(11), budget: 60, mode: .add)
        XCTAssertEqual(store.today.stops.map(\.id), [met.id, pizza.id])
        XCTAssertEqual(store.today.leg(after: met)?.mode, .drive)
        XCTAssertEqual(store.today.stops[1].start, met.end.addingTimeInterval(TimeInterval(store.today.legs[0].minutes * 60)),
                       "the time follows the drive, not the planner's subway")
    }

    // MARK: - Old files

    @MainActor func testFilesFromBeforeThisFeatureStillLoad() throws {
        let data = try SnapshotStore.encode(makeStore().snapshot)
        var json = String(decoding: data, as: UTF8.self)
        for key in ["extras", "costItems", "costIsCustom", "isChosen", "userCost"] {
            json = json.replacingOccurrences(of: #""\#(key)":(\[\]|false|true|\d+(\.\d+)?),?"#, with: "", options: .regularExpression)
            XCTAssertFalse(json.contains("\"\(key)\""), "\(key) should be stripped")
        }
        json = json.replacingOccurrences(of: ",}", with: "}")
        let snapshot = try SnapshotStore.decode(Data(json.utf8))
        XCTAssertEqual(snapshot.today.stops.count, 6)
        XCTAssertTrue(snapshot.today.extras.isEmpty)
        XCTAssertFalse(snapshot.today.stops[0].costIsCustom)
    }

    @MainActor func testUnknownTravelModeReadsAsWalking() throws {
        let leg = TravelLeg(fromStopID: UUID(), toStopID: UUID(), mode: .drive, minutes: 5, miles: 1)
        let data = try JSONEncoder().encode(leg)
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"drive\"", with: "\"scooter\"")
        XCTAssertEqual(try JSONDecoder().decode(TravelLeg.self, from: Data(json.utf8)).mode, .walk)
    }

    // MARK: - Price guide

    @MainActor func testTypicalPrices() {
        let food = PriceGuide.typical(.food)
        XCTAssertEqual(food.rangeText, "$15–30")
        XCTAssertEqual(food.perPersonText, "Usually $15–30 per person")
        XCTAssertEqual(food.sourceText, "Typical for food in NYC")
        XCTAssertEqual(food.estimate, 20)
        XCTAssertEqual(PriceGuide.typical(.outdoors).rangeText, "Free")
        XCTAssertEqual(PriceGuide.stated(6).rangeText, "$6")
        XCTAssertEqual(PriceGuide.stated(6).perPersonText, "$6 per person")
        XCTAssertEqual(PriceGuide.stated(2.9).rangeText, "$2.90")
        for category in PlaceCategory.allCases {
            let range = category.typicalPrice
            XCTAssertTrue(range.low <= range.estimate && range.estimate <= range.high, "\(category)")
        }
    }

    @MainActor func testPlannedCostPrefersTheUserThenThePostThenTypical() {
        var post = SampleData.tacosPost
        XCTAssertEqual(post.plannedCost, 15)
        post.estimatedCost = nil
        XCTAssertEqual(post.plannedCost, 20, "no price in the post: typical for food")
        post.userCost = 11
        XCTAssertEqual(post.plannedCost, 11)
    }

    @MainActor func testPlannerBudgetsTheTypicalPriceWhenThePostHasNone() {
        var post = SampleData.tacosPost
        post.estimatedCost = nil
        XCTAssertEqual(PlanCandidate(post: post)?.cost, 20)
    }

    // MARK: - Editing costs

    @MainActor func testSettingAStopsCost() {
        let store = makeStore()
        let id = store.today.stops[3].id
        let before = store.today.totalCost
        store.setCost(22, forStop: id)
        XCTAssertEqual(store.stop(id: id)?.estimatedCost, 22)
        XCTAssertTrue(store.stop(id: id)!.costIsCustom)
        XCTAssertEqual(store.today.totalCost, before + 7)
    }

    @MainActor func testItemsAddUpAndReplaceTheEstimate() {
        let store = makeStore()
        let id = store.today.stops[1].id // The Met, $5
        store.setCostItems([CostItem(name: "Ticket", amount: 17), CostItem(name: "Coffee", amount: 4.5)], forStop: id)
        XCTAssertEqual(store.stop(id: id)?.estimatedCost, 21.5)
        XCTAssertEqual(store.stop(id: id)?.costItems.count, 2)

        store.setCostItems([], forStop: id)
        XCTAssertEqual(store.stop(id: id)?.estimatedCost, 5, "no items left: back to the post's price")
        XCTAssertFalse(store.stop(id: id)!.costIsCustom)
    }

    @MainActor func testResetUsesTypicalWhenThereIsNoPost() {
        let store = makeStore()
        let pizza = store.today.stops[5] // no source post
        store.setCost(30, forStop: pizza.id)
        store.resetCost(forStop: pizza.id)
        XCTAssertEqual(store.stop(id: pizza.id)?.estimatedCost, PlaceCategory.food.typicalPrice.estimate)
        XCTAssertEqual(store.priceGuide(for: pizza).source, .typical(.food))
    }

    @MainActor func testCustomCostSurvivesReplanning() {
        let store = makeStore()
        let id = store.today.stops[3].id
        store.setCostItems([CostItem(name: "Tacos", amount: 12), CostItem(name: "Horchata", amount: 5)], forStop: id)
        store.buildPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(13), budget: 100, mode: .add)
        let stop = store.stop(id: id)
        XCTAssertEqual(stop?.estimatedCost, 17)
        XCTAssertEqual(stop?.costItems.map(\.name), ["Tacos", "Horchata"])
        XCTAssertTrue(stop?.costIsCustom == true)
    }

    @MainActor func testSavedPlacePriceFollowsIntoThePlan() {
        let store = makeStore()
        let tacos = store.today.stops[3]
        store.setUserCost(12, forPost: SampleData.tacosPost.id)
        XCTAssertEqual(store.stop(id: tacos.id)?.estimatedCost, 12)
        XCTAssertEqual(store.post(id: SampleData.tacosPost.id)?.plannedCost, 12)

        store.setCost(30, forStop: tacos.id)
        store.setUserCost(9, forPost: SampleData.tacosPost.id)
        XCTAssertEqual(store.stop(id: tacos.id)?.estimatedCost, 30, "a stop the user priced separately keeps its number")

        store.setUserCost(nil, forPost: SampleData.tacosPost.id)
        XCTAssertEqual(store.post(id: SampleData.tacosPost.id)?.plannedCost, 15)
    }

    // MARK: - Extras and the day's budget

    @MainActor func testExtrasCountTowardTheDay() {
        let store = makeStore()
        let before = store.today.totalCost
        store.setExtras([CostItem(name: "Snacks", amount: 8), CostItem(name: "Ride home", amount: 20)])
        XCTAssertEqual(store.today.totalCost, before + 28)
        XCTAssertTrue(store.today.shareText.contains("About \((before + 28).wholeDollarsText) per person"))
    }

    @MainActor func testExtrasCountAgainstThePlannersBudget() {
        let store = makeStore(plan: .empty(for: .now, budget: 30))
        let picks = [SampleData.tacosPost.id, SampleData.levainPost.id] // $15 + $6
        XCTAssertEqual(store.previewPlan(postIDs: picks, start: SampleData.at(11), budget: 30, mode: .replace).stops.count, 2)
        store.setExtras([CostItem(name: "Ride home", amount: 20)])
        let outcome = store.previewPlan(postIDs: picks, start: SampleData.at(11), budget: 30, mode: .replace)
        XCTAssertEqual(outcome.stops.count, 1)
        XCTAssertEqual(outcome.skipped.first?.reason, .overBudget)
    }

    @MainActor func testShareTextSplitsFaresAndRides() {
        let store = makeStore()
        store.chooseTravel(store.travelOptions(forLeg: legInto(5, store.today).id)[2])
        let text = store.today.shareText
        XCTAssertTrue(text.contains("including $5.80 in subway fares and $10 in rides"), text)
    }

    @MainActor func testRemainingText() {
        var plan = DayPlan(date: .now, title: "", budget: 60, stops: [], legs: [], extras: [CostItem(name: "x", amount: 57)])
        XCTAssertEqual(plan.remainingText, "$3 left")
        plan.extras = [CostItem(name: "x", amount: 72)]
        XCTAssertEqual(plan.remainingText, "$12 over")
        plan.extras = [CostItem(name: "x", amount: 60)]
        XCTAssertEqual(plan.remainingText, "Right on budget")
    }

    @MainActor func testTransitRideCounts() {
        let a = UUID(), b = UUID()
        let subway = TravelLeg.estimate(.subway, miles: 2, fromStopID: a, toStopID: b)
        let bus = TravelLeg.estimate(.bus, miles: 2, fromStopID: a, toStopID: b)
        XCTAssertEqual(BudgetSheet.transitText([subway, subway]), "2 subway rides")
        XCTAssertEqual(BudgetSheet.transitText([bus]), "1 bus ride")
        XCTAssertEqual(BudgetSheet.transitText([subway, bus]), "2 rides: 1 subway, 1 bus")
    }

    @MainActor func testCostLabelNeverContradictsTheNumber() {
        let food = PriceGuide.typical(.food)
        XCTAssertEqual(BudgetSheet.costSource(20, guide: food), "$15–30 · Typical for food in NYC")
        XCTAssertEqual(BudgetSheet.costSource(7, guide: food), "Less than the usual $15–30")
        XCTAssertEqual(BudgetSheet.costSource(45, guide: food), "More than the usual $15–30")
        XCTAssertEqual(BudgetSheet.costSource(9, guide: .stated(9)), "From the saved post")
    }

    @MainActor func testDollarFieldReadsWhatPeopleType() {
        XCTAssertEqual(DollarField.parse("12"), 12)
        XCTAssertEqual(DollarField.parse("$4.50"), 4.5)
        XCTAssertEqual(DollarField.parse(""), 0)
        XCTAssertEqual(DollarField.format(0), "")
        XCTAssertEqual(DollarField.format(8), "$8")
    }

    @MainActor func testBudgetCanBeChanged() {
        let store = makeStore()
        store.setBudget(75)
        XCTAssertEqual(store.today.budget, 75)
        store.setBudget(-5)
        XCTAssertEqual(store.today.budget, 0)
    }
}
