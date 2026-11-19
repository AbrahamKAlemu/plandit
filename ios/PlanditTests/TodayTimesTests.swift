import CoreLocation
import XCTest
@testable import Plandit

/// W-17: Today's times agree everywhere. A stop never starts before the earliest arrival its Time
/// sheet shows, and a trip shows the same minutes in the timeline and in the travel sheet.
@MainActor final class TodayTimesTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    /// Apple Maps stand-in whose times differ from Plandit's own estimates by a few minutes, like the real thing.
    @MainActor private final class FakeRoutes: RouteProviding {
        var extraMinutes = 3
        func route(_ mode: TravelMode, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> RouteInfo? {
            let miles = TravelLeg.streetMiles(
                from: Place(name: "", category: .food, neighborhood: "", address: "", latitude: from.latitude, longitude: from.longitude),
                to: Place(name: "", category: .food, neighborhood: "", address: "", latitude: to.latitude, longitude: to.longitude)
            )
            let estimate = TravelLeg.estimate(mode, miles: miles, fromStopID: UUID(), toStopID: UUID())
            return RouteInfo(minutes: estimate.minutes + extraMinutes, miles: miles, path: nil)
        }
    }

    private func makeStore(plan: DayPlan = SampleData.dayPlan) -> PlanditStore {
        PlanditStore(today: plan, saved: SampleData.savedPosts, profile: SampleData.profile, pastPlans: [], visited: [],
                     extractor: NoExtractor(), storage: nil, routes: FakeRoutes())
    }

    /// Every stop still ahead starts no earlier than the stop before it ends plus the trip there, and
    /// opening its Time sheet without touching anything shows the same times as the timeline.
    private func assertTimesAgree(_ store: PlanditStore, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let plan = store.today
        for stop in plan.stops where stop.status == .upcoming {
            if let earliest = plan.earliestStart(ofStop: stop.id) {
                XCTAssertGreaterThanOrEqual(
                    stop.start, earliest,
                    "\(context): \(stop.place.name) starts \(stop.start.shortTime) but the Time sheet says the earliest is \(earliest.shortTime)",
                    file: file, line: line
                )
            }
            let opened = store.previewTime(ofStop: stop.id, start: stop.start, durationMinutes: stop.durationMinutes, moveLaterStops: true)
            XCTAssertEqual(
                opened.stops.map(\.start), plan.stops.map(\.start),
                "\(context): opening \(stop.place.name)'s Time sheet shows different times", file: file, line: line
            )
        }
    }

    // MARK: - Earliest arrival

    func testSampleDayNeverStartsAStopBeforeItsEarliestArrival() {
        assertTimesAgree(makeStore(), "sample day")
    }

    func testPlannedDaysNeverStartAStopBeforeItsEarliestArrival() {
        let store = makeStore()
        let ids = store.plannablePosts.map(\.id)
        store.buildPlan(postIDs: ids, start: SampleData.at(10), budget: 500, mode: .replace)
        XCTAssertGreaterThan(store.today.stops.count, 2)
        assertTimesAgree(store, "a new plan")

        store.arrive(at: store.today.stops[0].id)
        store.buildPlan(postIDs: Array(ids.prefix(3)), start: SampleData.at(10), budget: 500, mode: .add)
        assertTimesAgree(store, "added to today")
    }

    func testEditsNeverStartAStopBeforeItsEarliestArrival() throws {
        let store = makeStore()
        store.buildPlan(postIDs: store.plannablePosts.map(\.id), start: SampleData.at(10), budget: 500, mode: .replace)
        store.arrive(at: store.today.stops[0].id)

        store.reorder(store.today.stops[1...].map(\.id).reversed())
        assertTimesAgree(store, "reordered")

        // Not an evening spot: one set before 8 PM goes back to 8 PM the next time an earlier stop changes.
        let stop = try XCTUnwrap(store.today.stops.dropFirst(2).first { $0.place.category.earliestStartMinutes == nil })
        store.setTime(ofStop: stop.id, start: stop.start.addingTimeInterval(-3600), durationMinutes: stop.durationMinutes, moveLaterStops: false)
        assertTimesAgree(store, "a time set too early")

        store.removeStop(store.today.stops[2].id)
        assertTimesAgree(store, "a stop removed")

        let leg = try XCTUnwrap(store.today.legs.last)
        let drive = try XCTUnwrap(store.travelOptions(forLeg: leg.id).first { $0.leg.mode == .drive })
        store.chooseTravel(drive)
        assertTimesAgree(store, "a trip changed")

        let unplanned = try XCTUnwrap(SampleData.savedPosts.first { $0.isMappable && !store.isInToday($0) })
        _ = store.addToToday(unplanned.id)
        assertTimesAgree(store, "a saved place added")
    }

    // MARK: - Timeline and travel sheet

    func testTravelSheetShowsTheTripAsPlannedOnceAppleMapsAnswers() async throws {
        let store = makeStore()
        for leg in store.today.legs where store.today.state(of: leg) != .completed {
            await store.loadTravelOptions(forLeg: leg.id)
            let rows = TravelOptionsSheet.rows(store.travelOptions(forLeg: leg.id), planned: leg)
            let planned = try XCTUnwrap(rows.first(where: \.isPlanned))
            XCTAssertEqual(planned.option.leg.mode, leg.mode)
            XCTAssertEqual(planned.option.leg.minutes, leg.minutes, "the picked way shows the timeline's \(leg.minutes) min")
            XCTAssertEqual(planned.source, "In your plan", "the plan's time isn't Apple Maps'")
            XCTAssertEqual(store.previewTravel(planned.option).stops.map(\.start), store.today.stops.map(\.start),
                           "its arrival time is the one on the timeline")

            // Apple Maps' time for the same way: offered under the row when it differs, never applied.
            let live = try XCTUnwrap(store.travelOptions(forLeg: leg.id).first { $0.leg.mode == leg.mode })
            XCTAssertTrue(live.isLive)
            if live.leg.minutes == leg.minutes {
                XCTAssertNil(planned.update)
            } else {
                XCTAssertEqual(planned.update, live, "\(leg.minutes) min planned, Apple Maps says \(live.leg.minutes)")
            }

            let others = rows.filter { !$0.isPlanned }
            XCTAssertEqual(others.count, TravelMode.choices.count - 1)
            XCTAssertTrue(others.allSatisfy { $0.option.isLive && $0.source == "From Apple Maps" && $0.update == nil },
                          "the other ways use Apple Maps and say so")
        }
    }

    func testTravelSheetMatchesTheTimelineAfterChoosingAnAppleMapsTime() async throws {
        let store = makeStore()
        let leg = try XCTUnwrap(store.today.legs.first { store.today.state(of: $0) == .upcoming && $0.mode != .subway })
        await store.loadTravelOptions(forLeg: leg.id)
        let subway = try XCTUnwrap(store.travelOptions(forLeg: leg.id).first { $0.leg.mode == .subway })
        XCTAssertTrue(subway.isLive)
        store.chooseTravel(subway)

        let planned = try XCTUnwrap(store.today.legs.first { $0.id == leg.id })
        let row = try XCTUnwrap(TravelOptionsSheet.rows(store.travelOptions(forLeg: leg.id), planned: planned).first(where: \.isPlanned))
        XCTAssertEqual(row.option.leg.mode, .subway)
        XCTAssertEqual(row.option.leg.minutes, planned.minutes)
        XCTAssertNil(row.update, "nothing newer to offer: the plan already has Apple Maps' time")
        assertTimesAgree(store, "after choosing the subway")
    }

    func testOnlyTheAppleMapsLineMovesTheDay() async throws {
        let store = makeStore()
        let leg = try XCTUnwrap(store.today.legs.first { store.today.state(of: $0) == .upcoming })
        await store.loadTravelOptions(forLeg: leg.id)
        let before = store.today.stops.map(\.start)
        let row = try XCTUnwrap(TravelOptionsSheet.rows(store.travelOptions(forLeg: leg.id), planned: leg).first(where: \.isPlanned))

        // Tapping the way it's already planned: the user's pick now, same time, nothing moves.
        store.chooseTravel(row.option)
        let kept = try XCTUnwrap(store.today.legs.first { $0.id == leg.id })
        XCTAssertTrue(kept.isChosen)
        XCTAssertEqual(kept.minutes, leg.minutes)
        XCTAssertEqual(store.today.stops.map(\.start), before)

        // "Apple Maps now says…": that time, and the stops after the trip move with it.
        let update = try XCTUnwrap(row.update, "Apple Maps' time differs from the plan's")
        store.chooseTravel(update)
        XCTAssertEqual(store.today.legs.first { $0.id == leg.id }?.minutes, update.leg.minutes)
        let destination = try XCTUnwrap(store.today.stops.firstIndex { $0.id == leg.toStopID })
        let moved = TimeInterval((update.leg.minutes - leg.minutes) * 60)
        XCTAssertEqual(store.today.stops[destination].start, before[destination].addingTimeInterval(moved))
        assertTimesAgree(store, "after taking Apple Maps' time")
    }

    func testRestOfTheDayKeepsTheTimesOfTripsAlreadyMadeThatWay() async throws {
        let store = makeStore()
        let ahead = store.today.legs.filter { store.today.state(of: $0) != .completed }
        for leg in ahead { await store.loadTravelOptions(forLeg: leg.id) }
        let walks = ahead.filter { $0.mode == .walk }
        let others = ahead.filter { $0.mode != .walk }
        XCTAssertFalse(walks.isEmpty)
        XCTAssertFalse(others.isEmpty)

        store.chooseTravelForRestOfDay(.walk)

        for walk in walks {
            let now = try XCTUnwrap(store.today.legs.first { $0.id == walk.id })
            XCTAssertEqual(now.minutes, walk.minutes, "a walk keeps its \(walk.minutes) min rather than taking Apple Maps' time")
            XCTAssertTrue(now.isChosen)
        }
        for other in others {
            let now = try XCTUnwrap(store.today.legs.first { $0.id == other.id })
            XCTAssertEqual(now.mode, .walk)
            XCTAssertTrue(now.isChosen)
        }
        assertTimesAgree(store, "walking the rest of the day")
    }
}
