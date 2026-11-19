import XCTest
@testable import Plandit

/// Sharing today's plan as a link (plandit.app/p/<slug>).
@MainActor final class SharedPlanTests: XCTestCase {
    private func cleanDay() -> DayPlan {
        var plan = SampleData.dayPlan
        for index in plan.stops.indices.dropFirst() {
            let previous = plan.stops[index - 1]
            plan.stops[index].start = previous.end.addingTimeInterval(TimeInterval(plan.leg(after: previous)!.minutes * 60))
        }
        return plan
    }

    private func makeStore(sharing: FakePlanSharing? = FakePlanSharing()) -> PlanditStore {
        let store = PlanditStore(today: cleanDay(), saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        return store
    }

    override func setUp() {
        super.setUp()
        PlanditStore.shareUpdateDelay = .milliseconds(50)
    }

    func testThePagePayloadHasEveryStopAndTripFormattedOnThePhone() {
        let plan = cleanDay()
        let payload = plan.sharedPayload(showPrices: true, note: "  Who's in?  ")
        XCTAssertEqual(payload.planId, plan.id)
        XCTAssertEqual(payload.title, plan.title)
        XCTAssertEqual(payload.note, "Who's in?")
        XCTAssertEqual(payload.stops.count, plan.stops.count)
        XCTAssertEqual(payload.legs.count, plan.stops.count - 1)
        XCTAssertEqual(payload.stops[1].name, "The Met")
        XCTAssertEqual(payload.stops[1].place, "Culture · Upper East Side")
        XCTAssertEqual(payload.stops[1].timeText, plan.stops[1].start.shortTime)
        XCTAssertEqual(payload.stops[1].costText, "$5")
        XCTAssertEqual(payload.legs[1].text, "35 min subway (4 and 7 trains, $2.90)")
        XCTAssertEqual(payload.costText, "About \(plan.totalCost.wholeDollarsText) per person")
        XCTAssertEqual(payload.timeText, "\(plan.stops[0].start.shortTime) – \(plan.stops.last!.end.shortTime)")
    }

    func testPricesCanBeLeftOff() {
        let payload = cleanDay().sharedPayload(showPrices: false, note: "")
        XCTAssertEqual(payload.costText, "")
        XCTAssertTrue(payload.stops.allSatisfy { $0.costText.isEmpty })
        XCTAssertFalse(payload.legs.contains { $0.text.contains("$") })
    }

    func testThePayloadMatchesTheServersFieldNames() throws {
        let data = try JSONEncoder().encode(cleanDay().sharedPayload(showPrices: true, note: ""))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["planId", "title", "dateText", "timeText", "note", "costText", "stops", "legs"])
        let stop = try XCTUnwrap((json["stops"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(stop.keys), ["name", "place", "address", "timeText", "durationText", "costText", "latitude", "longitude"])
    }

    func testCreatingAndStoppingALink() async throws {
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        XCTAssertNil(store.todayLink)
        let link = try await store.shareToday(showPrices: true, note: "Who's in?")
        XCTAssertEqual(link.url.absoluteString, "https://plandit.app/p/test123abc")
        XCTAssertEqual(store.todayLink, link)
        XCTAssertEqual(link.planID, store.today.id)
        let published = await sharing.published
        XCTAssertEqual(published.count, 1)

        try await store.stopSharing()
        XCTAssertNil(store.todayLink)
        let unpublished = await sharing.unpublished
        XCTAssertEqual(unpublished, ["test123abc"])
    }

    func testEditingASharedPlanUpdatesThePage() async throws {
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        try await store.shareToday(showPrices: true, note: "")
        store.removeStop(store.today.stops[3].id)
        try await Task.sleep(for: .milliseconds(400))
        let published = await sharing.published
        XCTAssertEqual(published.count, 2, "the change was published")
        XCTAssertFalse(published.last!.stops.contains { $0.name == "Los Tacos No. 1" })
    }

    func testChangesThatDontShowOnThePageDontUpload() async throws {
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        try await store.shareToday(showPrices: true, note: "")
        store.setBudget(store.today.budget + 5) // the page doesn't show the budget
        try await Task.sleep(for: .milliseconds(400))
        let count = await sharing.published.count
        XCTAssertEqual(count, 1)
    }

    func testAFailedLinkLeavesNothingBehind() async {
        let store = makeStore(sharing: FakePlanSharing(fails: true))
        do {
            try await store.shareToday(showPrices: true, note: "")
            XCTFail("should throw")
        } catch {}
        XCTAssertNil(store.todayLink)
    }

    func testWithoutAnAccountThereAreNoLinks() {
        XCTAssertFalse(makeStore(sharing: nil).canShareLinks)
    }

    func testTheLinkIsSavedWithThePlanAndOldFilesStillLoad() throws {
        var snapshot = makeStore().snapshot
        snapshot.sharedLink = SharedLink(slug: "abc", url: URL(string: "https://plandit.app/p/abc")!, planID: snapshot.today.id, showPrices: false, note: "hi")
        let data = try SnapshotStore.encode(snapshot)
        XCTAssertEqual(try SnapshotStore.decode(data).sharedLink, snapshot.sharedLink)

        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "sharedLink")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        XCTAssertNil(try SnapshotStore.decode(oldData).sharedLink)

        let store = PlanditStore(snapshot: try SnapshotStore.decode(data))
        XCTAssertEqual(store.todayLink?.slug, "abc")
    }
}
