import XCTest
@testable import Plandit

/// Smart "Add to today" and reordering the stops still ahead.
/// Sample day: Pastry (done) → Met (now) → High Line → Tacos → Washington Sq → Joe's.
@MainActor final class PlanEditingTests: XCTestCase {
    private let calendar = Calendar.current

    private func cleanDay() -> DayPlan {
        var plan = SampleData.dayPlan
        for index in plan.stops.indices.dropFirst() {
            let previous = plan.stops[index - 1]
            plan.stops[index].start = previous.end.addingTimeInterval(TimeInterval(plan.leg(after: previous)!.minutes * 60))
        }
        return plan
    }

    /// Early on the plan's day, so "now" never pushes anything.
    private func morning(of plan: DayPlan) -> Date {
        calendar.date(bySettingHour: 8, minute: 0, second: 0, of: plan.stops[0].start)!
    }

    private func at(_ hour: Int, _ minute: Int = 0, on plan: DayPlan) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: plan.stops[0].start)!
    }

    private func candidate(_ place: Place, minutes: Int? = nil, cost: Double = 0) -> PlanCandidate {
        PlanCandidate(place: place, cost: cost, durationMinutes: minutes)
    }

    private func place(_ name: String, _ latitude: Double, _ longitude: Double, hours: String? = nil, category: PlaceCategory = .food) -> Place {
        Place(name: name, category: category, neighborhood: "Test", address: "\(name) St", latitude: latitude, longitude: longitude, hours: hours)
    }

    /// Every trip joins two stops that are next to each other, and nothing ahead overlaps.
    private func assertConsistent(_ plan: DayPlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.legs.count, max(0, plan.stops.count - 1), file: file, line: line)
        for (leg, (from, to)) in zip(plan.legs, zip(plan.stops, plan.stops.dropFirst())) {
            XCTAssertEqual(leg.fromStopID, from.id, file: file, line: line)
            XCTAssertEqual(leg.toStopID, to.id, file: file, line: line)
            if to.status == .upcoming {
                XCTAssertGreaterThanOrEqual(to.start, from.end.addingTimeInterval(TimeInterval(leg.minutes * 60)), "\(to.place.name) overlaps", file: file, line: line)
            }
        }
    }

    // MARK: - Adding

    func testANearbyPlaceGoesNextToItsNeighborNotAtTheEnd() {
        let plan = cleanDay()
        // Levain is a few blocks from the Met, and miles from Joe's at the end of the day.
        let result = plan.inserting(candidate(SampleData.levain), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertEqual(result.position, 2, "right after the Met")
        XCTAssertEqual(result.lateMinutes, 0)
        assertConsistent(result.plan)
        XCTAssertEqual(result.plan.stops.count, 7)
    }

    func testNeverGoesBeforeStopsDoneOrUnderway() {
        let plan = cleanDay()
        // Next door to the Hungarian Pastry Shop, which is done.
        let nearPastry = place("Corner Deli", 40.8040, -73.9640)
        let result = plan.inserting(candidate(nearPastry), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertGreaterThanOrEqual(result.position, 2)
        XCTAssertEqual(result.plan.stops[0].start, plan.stops[0].start)
        XCTAssertEqual(result.plan.stops[1].start, plan.stops[1].start)
        assertConsistent(result.plan)
    }

    func testAPlaceClosingSoonGoesWhereItsStillOpen() {
        var plan = cleanDay()
        plan.stops = Array(plan.stops.prefix(2)) // Pastry (done), Met (now, until 12:45)
        plan.relinkLegs(travel: .walkAndTransit)
        // A long evening stop right next to the new place, far from the Met.
        let downtown = place("Downtown Hall", 40.7060, -74.0090, category: .culture)
        plan = plan.inserting(candidate(downtown, minutes: 300), travel: .walkAndTransit, now: morning(of: plan)).plan
        let nextDoor = place("Closes At Five", 40.7065, -74.0095, hours: "Open until 5 PM")

        let result = plan.inserting(candidate(nextDoor, minutes: 45), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertEqual(result.lateMinutes, 0, "after Downtown Hall it would be closed, so it goes before")
        XCTAssertEqual(result.position, 2)
        XCTAssertLessThan(result.stop.end, at(17, on: plan).addingTimeInterval(1))
        assertConsistent(result.plan)
    }

    func testAVisitIsShortenedToEndAtClosing() {
        var plan = cleanDay()
        plan.stops = Array(plan.stops.prefix(2))
        plan.relinkLegs(travel: .walkAndTransit)
        let closesSoon = place("Closes At Two", 40.7800, -73.9640, hours: "Open until 2 PM")
        let result = plan.inserting(candidate(closesSoon, minutes: 120), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertEqual(result.lateMinutes, 0)
        XCTAssertEqual(result.stop.end, at(14, on: plan), "the Met ends 12:45, so 120 minutes becomes about 70")
    }

    func testWhenNoSlotIsOpenLongEnoughTheVisitStillEndsAtClosing() {
        let plan = cleanDay()
        // Levain closes at 8 PM; at 7:47 there's only time for a quick stop.
        let result = plan.inserting(candidate(SampleData.levain), travel: .walkAndTransit, now: at(19, 47, on: plan))
        XCTAssertGreaterThan(result.lateMinutes, 0)
        XCTAssertEqual(result.stop.end, at(20, on: plan))
        assertConsistent(result.plan)
    }

    func testEveningSpotsStartAtEightOrLater() {
        let plan = cleanDay()
        let result = plan.inserting(candidate(SampleData.smalls), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertGreaterThanOrEqual(result.stop.start, at(20, on: plan))
        assertConsistent(result.plan)
    }

    func testLaterStopsOnlyMoveAsMuchAsTheyHaveTo() {
        var plan = cleanDay()
        // Two free hours before Joe's.
        plan.stops[5].start = plan.stops[5].start.addingTimeInterval(2 * 3600)
        let joes = plan.stops[5].start
        // A short stop right by Washington Square fits in the gap.
        let nearPark = place("Park Coffee", 40.7310, -73.9975, category: .coffee)
        let result = plan.inserting(candidate(nearPark, minutes: 30), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertEqual(result.position, 5)
        XCTAssertEqual(result.plan.stops.last?.start, joes, "the gap absorbs it")
        assertConsistent(result.plan)
    }

    func testDoesntStartInThePast() {
        let plan = cleanDay()
        let now = at(15, 7, on: plan)
        // Normally goes right after the Met (12:45), but it's already 3:07.
        let result = plan.inserting(candidate(SampleData.levain), travel: .walkAndTransit, now: now)
        XCTAssertGreaterThanOrEqual(result.stop.start, now)
        XCTAssertEqual(calendar.component(.minute, from: result.stop.start) % 5, 0, "rounded to 5 minutes")
    }

    func testAnEmptyDayStartsNow() {
        var plan = cleanDay()
        plan.stops = []
        plan.legs = []
        let now = at(14, 2, on: SampleData.dayPlan)
        let result = plan.inserting(candidate(SampleData.levain), travel: .walkAndTransit, now: now)
        XCTAssertEqual(result.plan.stops.count, 1)
        XCTAssertEqual(result.stop.start, at(14, 5, on: SampleData.dayPlan))
        XCTAssertTrue(result.plan.legs.isEmpty)
    }

    func testATripTheUserPickedStaysWhenItsStopsAreStillNeighbors() {
        var plan = cleanDay()
        var drive = TravelLeg.estimate(.drive, miles: 1, fromStopID: plan.stops[4].id, toStopID: plan.stops[5].id)
        drive.id = plan.legs[4].id
        drive.isChosen = true
        plan.setLeg(drive)
        let result = plan.inserting(candidate(SampleData.levain), travel: .walkAndTransit, now: morning(of: plan))
        XCTAssertEqual(result.plan.leg(after: result.plan.stops.first { $0.id == plan.stops[4].id }!)?.mode, .drive)
    }

    @MainActor func testStoreAddsInTheBestSlotAndNamesAnEmptyDay() {
        let store = PlanditStore(today: cleanDay(), saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        let id = store.addToToday(SampleData.levainPost.id)
        XCTAssertNotNil(id)
        XCTAssertEqual(store.today.stops.count, 7)
        XCTAssertTrue(store.isInToday(SampleData.levainPost))
        assertConsistent(store.today)

        var empty = cleanDay()
        empty.stops = []
        empty.legs = []
        empty.title = ""
        let fresh = PlanditStore(today: empty, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        fresh.addToToday(SampleData.levainPost.id)
        XCTAssertFalse(fresh.today.title.isEmpty)
    }

    // MARK: - Reordering

    func testReorderingRetimesTheStopsAheadOneAfterAnother() {
        let plan = cleanDay()
        let ahead = plan.stops[2...].map(\.id)
        let swapped = [ahead[1], ahead[0], ahead[2], ahead[3]] // Tacos before the High Line
        let result = plan.reordered(swapped, travel: .walkAndTransit)
        XCTAssertEqual(result.stops.map(\.id), plan.stops[..<2].map(\.id) + swapped)
        XCTAssertEqual(result.stops[0].start, plan.stops[0].start)
        XCTAssertEqual(result.stops[1].start, plan.stops[1].start)
        XCTAssertGreaterThanOrEqual(result.stops[2].start, plan.stops[2].start, "starts no earlier than the slot did")
        assertConsistent(result)
        for index in 3..<result.stops.count {
            let previous = result.stops[index - 1]
            let arrive = previous.end.addingTimeInterval(TimeInterval(result.leg(after: previous)!.minutes * 60))
            XCTAssertLessThan(result.stops[index].start.timeIntervalSince(arrive), 5 * 60, "no gaps beyond rounding")
        }
    }

    func testReorderingKeepsTripsBetweenStopsThatStayNeighbors() {
        let plan = cleanDay()
        let ahead = plan.stops[2...].map(\.id)
        let result = plan.reordered([ahead[0], ahead[1], ahead[3], ahead[2]], travel: .walkAndTransit)
        XCTAssertEqual(result.legs[2].id, plan.legs[2].id, "High Line → Tacos is unchanged")
    }

    func testReorderingIgnoresListsThatDontMatchTheStopsAhead() {
        let plan = cleanDay()
        let ahead = plan.stops[2...].map(\.id)
        XCTAssertEqual(plan.reordered(Array(ahead.dropLast()), travel: .walkAndTransit).stops, plan.stops, "missing a stop")
        XCTAssertEqual(plan.reordered([plan.stops[1].id] + ahead.dropLast(), travel: .walkAndTransit).stops, plan.stops, "a stop underway can't move")
        XCTAssertEqual(plan.reordered(ahead + [UUID()], travel: .walkAndTransit).stops, plan.stops, "an extra stop")
        let overlapping = SampleData.dayPlan // the High Line starts before you can get there from the Met
        XCTAssertEqual(overlapping.reordered(overlapping.stops[2...].map(\.id), travel: .walkAndTransit).stops, overlapping.stops,
                       "the same order changes nothing, not even times")
    }

    func testReorderingAnEveningSpotEarlyStillWaitsForEight() {
        var plan = cleanDay()
        plan.stops[5].place = SampleData.smalls
        let ahead = plan.stops[2...].map(\.id)
        let result = plan.reordered([ahead[3]] + ahead.dropLast(), travel: .walkAndTransit)
        XCTAssertEqual(result.stops[2].place.name, SampleData.smalls.name)
        XCTAssertGreaterThanOrEqual(result.stops[2].start, at(20, on: plan))
        assertConsistent(result)
    }

    @MainActor func testStoreReorderSavesAndPreviewDoesNot() {
        let store = PlanditStore(today: cleanDay(), saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        let before = store.today.stops.map(\.id)
        let ahead = Array(before[2...])
        let swapped = [ahead[1], ahead[0], ahead[2], ahead[3]]
        XCTAssertEqual(store.previewReorder(swapped).stops.map(\.id), Array(before[..<2]) + swapped)
        XCTAssertEqual(store.today.stops.map(\.id), before)
        store.reorder(swapped)
        XCTAssertEqual(store.today.stops.map(\.id), Array(before[..<2]) + swapped)
        assertConsistent(store.today)
    }

    // MARK: - Catching up with the clock

    func testNothingIsOverdueUntilTenMinutesAfterAStopsTime() {
        let plan = cleanDay()
        let metEnds = plan.stops[1].end // the Met is underway
        XCTAssertTrue(plan.overdueStops(now: plan.stops[1].start).isEmpty)
        XCTAssertTrue(plan.overdueStops(now: metEnds.addingTimeInterval(9 * 60)).isEmpty)
        XCTAssertEqual(plan.overdueStops(now: metEnds.addingTimeInterval(10 * 60)).map(\.place.name), ["The Met"])
    }

    func testMarkingOverdueStopsDoneMakesTheOneStartedNow() {
        var plan = cleanDay()
        let now = plan.stops[4].start.addingTimeInterval(5 * 60) // just after Washington Square starts
        let overdue = plan.overdueStops(now: now).map(\.id)
        XCTAssertEqual(overdue, plan.stops[1...3].map(\.id))
        plan.markOverdueDone(now: now)
        XCTAssertEqual(plan.stops.map(\.status), [.done, .done, .done, .done, .now, .upcoming])
        XCTAssertTrue(plan.overdueStops(now: now).isEmpty)
    }

    func testMarkingDoneBeforeTheNextStopStartsLeavesItAhead() {
        var plan = cleanDay()
        let now = plan.stops[1].end.addingTimeInterval(11 * 60) // on the way to the High Line
        plan.markOverdueDone(now: now)
        XCTAssertEqual(plan.stops.map(\.status), [.done, .done, .upcoming, .upcoming, .upcoming, .upcoming])
    }

    func testStillHereRunsTheStopUntilNowAndMovesTheRestLater() {
        var plan = cleanDay()
        let before = plan.stops
        let now = before[1].end.addingTimeInterval(17 * 60)
        let roundedNow = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300)
        plan.startRestFromNow(now: now)
        XCTAssertEqual(plan.stops[1].end, roundedNow, "the Met runs until now")
        XCTAssertEqual(plan.stops[1].status, .now)
        let moved = roundedNow.timeIntervalSince(before[1].end)
        XCTAssertEqual(plan.stops[2].start, before[2].start.addingTimeInterval(moved))
        XCTAssertEqual(plan.stops[5].start, before[5].start.addingTimeInterval(moved))
        XCTAssertTrue(plan.overdueStops(now: now).isEmpty)
    }

    func testStartFromNowMovesTheFirstMissedStopToNow() {
        var plan = cleanDay()
        plan.stops[1].status = .done // left the Met, never tapped anything after
        let before = plan.stops
        let now = at(16, 3, on: plan)
        plan.startRestFromNow(now: now)
        XCTAssertEqual(plan.stops[2].start, at(16, 5, on: plan))
        let moved = plan.stops[2].start.timeIntervalSince(before[2].start)
        XCTAssertEqual(plan.stops[5].start, before[5].start.addingTimeInterval(moved))
        XCTAssertTrue(plan.overdueStops(now: now).isEmpty)
        assertConsistent(plan)
    }

    func testTripTextOnThePostScreen() {
        let plan = cleanDay()
        XCTAssertEqual(TodayPlacementText.trip(plan.legs[2], from: plan.stops[2]), "\(plan.legs[2].minutes.durationText) walk from The High Line")
    }
}
