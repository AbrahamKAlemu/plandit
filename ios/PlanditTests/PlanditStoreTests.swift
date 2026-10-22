import XCTest
@testable import Plandit

final class PlanditStoreTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult() }
    }

    @MainActor private func stop(_ place: Place, hour: Int, status: StopStatus = .upcoming) -> PlanStop {
        PlanStop(place: place, start: SampleData.at(hour), durationMinutes: 60, estimatedCost: 10, status: status)
    }

    @MainActor private func makeStore(stops: [PlanStop] = [], saved: [SavedPost] = [], date: Date = .now, storage: SnapshotStore? = nil) -> PlanditStore {
        var plan = DayPlan(date: date, title: "Test day", budget: 60, stops: stops, legs: [])
        plan.legs = zip(plan.stops, plan.stops.dropFirst()).map { .estimate(from: $0, to: $1) }
        return PlanditStore(
            today: plan, saved: saved, profile: SampleData.profile, stats: SampleData.stats,
            pastPlans: [], visited: [], extractor: NoExtractor(), storage: storage
        )
    }

    @MainActor private func threeStops() -> [PlanStop] {
        [stop(SampleData.hungarianPastry, hour: 9), stop(SampleData.met, hour: 11), stop(SampleData.highLine, hour: 14)]
    }

    @MainActor func testArriveMarksEarlierStopsDoneAndLaterOnesUpcoming() {
        let store = makeStore(stops: threeStops())
        store.arrive(at: store.today.stops[1].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .now, .upcoming])
    }

    @MainActor func testCompleteAdvancesToTheNextStop() {
        let store = makeStore(stops: threeStops())
        store.complete(store.today.stops[0].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .now, .upcoming])
        store.complete(store.today.stops[2].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .done, .done])
        XCTAssertTrue(store.today.isComplete)
    }

    @MainActor func testAddToTodayAppendsStopWithEstimatedLeg() {
        let post = SampleData.levainPost
        let store = makeStore(stops: [stop(SampleData.hungarianPastry, hour: 9)], saved: [post])
        let stopID = store.addToToday(post.id)
        XCTAssertNotNil(stopID)
        XCTAssertEqual(store.today.stops.count, 2)
        XCTAssertEqual(store.today.stops.last?.place.name, "Levain Bakery")
        XCTAssertEqual(store.today.stops.last?.estimatedCost, 6)
        XCTAssertEqual(store.today.legs.count, 1)
        XCTAssertTrue(store.isInToday(post))

        XCTAssertNil(store.addToToday(post.id), "adding the same post twice is a no-op")
        XCTAssertEqual(store.today.stops.count, 2)
    }

    @MainActor func testRemovingAMiddleStopRebuildsLegs() {
        let store = makeStore(stops: threeStops())
        store.removeStop(store.today.stops[1].id)
        XCTAssertEqual(store.today.stops.count, 2)
        XCTAssertEqual(store.today.legs.count, 1)
        XCTAssertEqual(store.today.legs.first?.fromStopID, store.today.stops[0].id)
        XCTAssertEqual(store.today.legs.first?.toStopID, store.today.stops[1].id)
    }

    @MainActor func testRollOverFilesYesterdaysPlanAndStartsTodayEmpty() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let store = makeStore(stops: threeStops(), date: yesterday)
        store.rollOverIfNeeded()
        XCTAssertTrue(store.today.stops.isEmpty)
        XCTAssertTrue(Calendar.current.isDateInToday(store.today.date))
        XCTAssertEqual(store.today.budget, SampleData.profile.defaultBudget)
        XCTAssertEqual(store.pastPlans.first?.title, "Test day")
        XCTAssertEqual(store.pastPlans.first?.stopCount, 3)
        XCTAssertEqual(store.visited.count, 3)
    }

    @MainActor func testRollOverLeavesTodayAlone() {
        let store = makeStore(stops: threeStops())
        store.rollOverIfNeeded()
        XCTAssertEqual(store.today.stops.count, 3)
        XCTAssertTrue(store.pastPlans.isEmpty)
    }

    @MainActor func testSnapshotRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanditStoreTests-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }

        let store = makeStore(stops: threeStops(), saved: [SampleData.levainPost, SampleData.failedPost], storage: storage)
        store.updateProfile { $0.homeBase = "Harlem" }
        store.flush()

        let loaded = try XCTUnwrap(storage.load())
        XCTAssertEqual(loaded.today.stops.map(\.id), store.today.stops.map(\.id))
        XCTAssertEqual(loaded.today.legs.count, 2)
        XCTAssertEqual(loaded.saved.map(\.id), store.saved.map(\.id))
        XCTAssertEqual(loaded.saved.map(\.status), [.ready, .failed])
        XCTAssertEqual(loaded.profile.homeBase, "Harlem")
    }

    @MainActor func testIngestPendingSharesSavesEachLinkOnce() {
        let store = makeStore()
        let url = URL(string: "https://www.tiktok.com/@someone/video/7400000000000000099")!
        ShareInbox.enqueue(IncomingShare(url: url, sharedText: "caption"))
        ShareInbox.enqueue(IncomingShare(url: url))

        let ids = store.ingestPendingShares()
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.caption, "caption")
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }
}
