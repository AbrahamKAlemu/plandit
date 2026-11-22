import XCTest
@testable import Plandit

/// "Ask friends what works" in the organizer's app (group plans, mode 2): the link (GI-1), the
/// answers screen's refresh and removals (GI-4, GS-4), and "Build our plan", which builds into
/// Today from everyone's inputs (GI-5) and puts the plan on the link (GI-7).
@MainActor final class PlanRequestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlanditStore.shareUpdateDelay = .milliseconds(50)
        PlanditStore.requestRefreshInterval = 10
    }

    // MARK: - The server's JSON

    func testDecodesTheServersRequest() throws {
        let place = UUID(), star = UUID()
        let json = """
        {"slug": "Ab3dE6gH9k", "url": "https://plandit.app/g/Ab3dE6gH9k", "status": "open",
         "places": [{"id": "\(place.uuidString.lowercased())", "name": "Levain", "neighborhood": "UWS", "kind": "Food", "costText": "$6"},
                    {"id": "not-a-uuid", "name": "?", "neighborhood": "", "kind": "", "costText": ""}],
         "day": "2026-11-22", "windowStart": "12:00", "windowEnd": "20:00", "timeZone": "America/New_York",
         "answersBy": "2026-11-22T17:00:00Z", "planSlug": null, "createdAt": "2026-11-22T14:00:00.123456Z",
         "answers": [
           {"id": "6f1c2a4e-1b2c-4d3e-8f90-a1b2c3d4e5f6", "name": "Maya", "budget": 20, "freeFrom": "13:00",
            "freeUntil": "18:30", "stars": ["\(star.uuidString.lowercased())"],
            "createdAt": "2026-11-22T15:00:00Z", "updatedAt": "2026-11-22T15:01:00Z"},
           {"id": "7a1c2a4e-1b2c-4d3e-8f90-a1b2c3d4e5f6", "name": "Who", "budget": 20, "freeFrom": "1 PM",
            "freeUntil": "18:00", "stars": [], "createdAt": "2026-11-22T15:00:00Z", "updatedAt": "2026-11-22T15:00:00Z"}
         ]}
        """
        let request = try PlanRequest.decode(Data(json.utf8))
        XCTAssertEqual(request.slug, "Ab3dE6gH9k")
        XCTAssertEqual(request.status, .open)
        XCTAssertEqual(request.placeIDs, [place])
        XCTAssertEqual(request.answersBy, ISO8601DateFormatter().date(from: "2026-11-22T17:00:00Z"))
        XCTAssertNil(request.planSlug)
        XCTAssertEqual(request.answers.map(\.name), ["Maya"], "an answer this build can't read is skipped, not the request")
        XCTAssertEqual(request.answers[0].freeFrom, ClockTime(13))
        XCTAssertEqual(request.answers[0].freeUntil, ClockTime(18, 30))
        XCTAssertEqual(request.answers[0].stars, [star], "ids match whatever their case")
    }

    func testTheDraftIsWhatTheServerTakes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9))!
        let answersBy = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 11, minute: 30))!
        let draft = PlanRequestDraft(posts: [SampleData.levainPost, SampleData.processingPost, SampleData.highLinePost],
                                     day: day, start: ClockTime(12), end: ClockTime(20), answersBy: answersBy, calendar: calendar)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["places", "day", "windowStart", "windowEnd", "timeZone", "answersBy"])
        XCTAssertEqual(json["day"] as? String, "2026-11-22")
        XCTAssertEqual(json["windowStart"] as? String, "12:00")
        XCTAssertEqual(json["windowEnd"] as? String, "20:00")
        XCTAssertEqual(json["timeZone"] as? String, "America/New_York")
        XCTAssertEqual(json["answersBy"] as? String, "2026-11-22T16:30:00Z")
        let places = try XCTUnwrap(json["places"] as? [[String: String]])
        XCTAssertEqual(places.count, 2, "a save without a place is left out")
        XCTAssertEqual(places[0]["id"], SampleData.levainPost.id.uuidString)
        XCTAssertEqual(places[0]["name"], "Levain Bakery")
        XCTAssertEqual(places[0]["costText"], "$6")
        XCTAssertEqual(places[1]["costText"], "Free")
    }

    func testTheClientUsesTheOwnersEndpoints() async throws {
        let body = Data(requestJSON(slug: "Ab3dE6gH9k").utf8)
        let transport = FakeTransport { request in
            request.httpMethod == "POST" && request.url!.absoluteString.hasSuffix("/plan-requests/") ? (201, body) : (204, Data())
        }
        let client = PlanRequestClient(api: api(transport))
        let created = try await client.create(draft())
        XCTAssertEqual(created.slug, "Ab3dE6gH9k")
        XCTAssertEqual(transport.requests("POST", pathContaining: "api/plan-requests/").count, 1)

        try await client.close(slug: "Ab3dE6gH9k")
        XCTAssertEqual(transport.requests("POST", pathContaining: "api/plan-requests/Ab3dE6gH9k/close/").count, 1)
        let answer = UUID()
        try await client.removeAnswer(slug: "Ab3dE6gH9k", answerID: answer)
        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/plan-requests/Ab3dE6gH9k/answers/\(answer.uuidString)/").count, 1)

        // Gone is what the organizer wanted when deleting or removing; reading it is nil.
        transport.respond { _ in (404, Data(#"{"detail": "Not found."}"#.utf8)) }
        try await client.delete(slug: "Ab3dE6gH9k")
        try await client.removeAnswer(slug: "Ab3dE6gH9k", answerID: answer)
        let gone = try await client.fetch(slug: "Ab3dE6gH9k")
        XCTAssertNil(gone)
        XCTAssertEqual(transport.requests("GET", pathContaining: "api/plan-requests/Ab3dE6gH9k/").count, 1)

        transport.respond { _ in (500, Data()) }
        do {
            _ = try await client.fetch(slug: "Ab3dE6gH9k")
            XCTFail("a server error is an error, not a missing request")
        } catch {}
    }

    // MARK: - The link

    func testCreatingKeepsTheLinkButNotTheAnswers() async throws {
        let (store, _) = try await requestedStore()
        let link = try XCTUnwrap(store.planRequest)
        XCTAssertEqual(link.slug, "req1")
        XCTAssertEqual(link.url, URL(string: "https://plandit.app/g/req1"))
        XCTAssertEqual(link.placeIDs, places.map(\.id))
        XCTAssertEqual(store.snapshot.planRequest, link, "kept like today's link, so it survives a relaunch and syncs")
        XCTAssertEqual(PlanditStore(snapshot: store.snapshot).planRequest, link)
        let saved = String(data: try JSONEncoder().encode(store.snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(saved.contains("Maya"), "friends' answers are never saved")
    }

    func testAnswersRefreshAtMostEveryTenSeconds() async throws {
        let (store, requests) = try await requestedStore()
        await requests.setAnswers([answer("Maya", budget: 20, 13, 18)])
        let start = Date().addingTimeInterval(11)
        await store.refreshPlanRequest(now: start)
        await store.refreshPlanRequest(now: start.addingTimeInterval(5))
        var fetches = await requests.fetches
        XCTAssertEqual(fetches, 1, "the screen appearing again within 10 s doesn't ask again")
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Maya"])

        await store.refreshPlanRequest(now: start.addingTimeInterval(11))
        fetches = await requests.fetches
        XCTAssertEqual(fetches, 2, "after 10 s it does")
        await store.refreshPlanRequest(now: start.addingTimeInterval(12), force: true)
        fetches = await requests.fetches
        XCTAssertEqual(fetches, 3, "pull to refresh always asks")
    }

    func testARemovedAnswerDoesntComeBackFromAnOlderRefresh() async throws {
        let (store, requests) = try await requestedStore()
        let maya = answer("Maya", budget: 20, 13, 18), jordan = answer("Jordan", budget: 35, 12, 17)
        await requests.setAnswers([maya, jordan])
        await store.refreshPlanRequest(force: true)
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Maya", "Jordan"])

        await requests.holdNext()
        let refresh = Task { await store.refreshPlanRequest(force: true) }
        try await waitUntilHeld(requests)
        try await store.removeRequestAnswer(maya.id)
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Jordan"])
        await requests.release()
        await refresh.value
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Jordan"], "the refresh read Maya before she was removed")
        let removed = await requests.removed
        XCTAssertEqual(removed, [maya.id])

        await store.refreshPlanRequest(force: true)
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Jordan"])
    }

    func testClosingStopsAnswersButKeepsTheLink() async throws {
        let (store, requests) = try await requestedStore()
        try await store.closePlanRequest()
        XCTAssertEqual(store.requestDetails?.status, .closed)
        XCTAssertNotNil(store.planRequest)
        let closed = await requests.closed
        XCTAssertEqual(closed, ["req1"])
    }

    func testALinkTheServerNoLongerHasIsForgotten() async throws {
        let (store, requests) = try await requestedStore()
        await requests.setGone()
        await store.refreshPlanRequest(force: true)
        XCTAssertNil(store.planRequest)
        XCTAssertNil(store.requestDetails)
        XCTAssertNil(store.snapshot.planRequest)
    }

    func testAFailedRefreshKeepsWhatWasShown() async throws {
        let (store, requests) = try await requestedStore()
        await requests.setAnswers([answer("Maya", budget: 20, 13, 18)])
        await store.refreshPlanRequest(force: true)
        await requests.failNext()
        await store.refreshPlanRequest(force: true)
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Maya"])
        XCTAssertNotNil(store.planRequest)
    }

    func testAskingAboutAnotherDayDeletesALinkWithoutAPlan() async throws {
        let (store, requests) = try await requestedStore()
        try await store.discardPlanRequest()
        XCTAssertNil(store.planRequest)
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, ["req1"])
    }

    func testAskingAboutAnotherDayKeepsALinkThatOpensAPlan() async throws {
        let (store, requests) = try await requestedStore()
        await requests.setStatus(.built)
        await store.refreshPlanRequest(force: true)
        try await store.discardPlanRequest()
        XCTAssertNil(store.planRequest)
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, [], "friends' link keeps opening the plan")
    }

    func testALinkForAnEarlierDayIsNoLongerActive() async throws {
        let (store, _) = try await requestedStore()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: elevenAM)!
        XCTAssertNotNil(store.activeRequest(now: elevenAM))
        XCTAssertNil(store.activeRequest(now: tomorrow))
    }

    // MARK: - Build our plan (GI-5, GI-7)

    func testBuildOurPlanUsesEveryonesInputsAndPutsThePlanOnTheLink() async throws {
        // The DEBUG fake: Maya $20, 1 to 6 PM, stars tacos and the High Line; Jordan $35, noon to 5 PM,
        // stars tacos and Levain. The organizer: $60, the whole 12 to 8 PM.
        let sharing = FakePlanSharing()
        let store = makeStore(sharing: sharing)
        store.requestClient = FakePlanRequests(sharing: sharing, clashes: false)
        let draft = draft()
        try await store.createPlanRequest(draft, answersBy: elevenAM.addingTimeInterval(3600))
        await store.refreshPlanRequest(force: true)
        let link = try XCTUnwrap(store.planRequest)

        let result = try XCTUnwrap(store.groupInputs(organizer: store.organizerInputs(for: link), leftOut: []))
        guard case .ready(let plan) = result else { return XCTFail("expected a plan, got \(result)") }
        XCTAssertEqual(plan.start, ClockTime(13))
        XCTAssertEqual(plan.end, ClockTime(17))
        XCTAssertEqual(plan.budget, 20)
        XCTAssertEqual(plan.candidates.map(\.placeID), [SampleData.tacosPost.id, SampleData.highLinePost.id,
                                                         SampleData.levainPost.id, SampleData.littleIslandPost.id])
        XCTAssertEqual(plan.candidates.map(\.stars), [2, 1, 1, 0])

        let before = store.today.stops.map(\.id)
        let outcome = try XCTUnwrap(store.buildGroupPlan(plan, now: elevenAM))
        XCTAssertFalse(outcome.stops.isEmpty)
        XCTAssertEqual(store.today.stops.map(\.id), outcome.stops.map(\.id), "it replaces today's plan")
        XCTAssertEqual(store.today.budget, 20)
        XCTAssertLessThanOrEqual(outcome.cost, 20)
        XCTAssertTrue(outcome.stops.contains { $0.sourcePostID == SampleData.tacosPost.id }, "the most-starred place stays")
        let day = try XCTUnwrap(link.dayDate)
        XCTAssertGreaterThanOrEqual(outcome.stops[0].start, ClockTime(13).date(on: day, calendar: link.calendar)!)
        XCTAssertLessThanOrEqual(outcome.end ?? .distantFuture, ClockTime(17).date(on: day, calendar: link.calendar)!)
        XCTAssertEqual(store.planRequest?.builtPlanID, store.today.id)
        XCTAssertNotNil(store.undo)

        try await store.shareGroupPlan()
        let published = await sharing.published
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.last?.request, "req123abcd", "the plan goes out with the request's slug (GI-7)")
        XCTAssertEqual(published.last?.stops.map(\.id), store.today.stops.map(\.id))
        XCTAssertEqual(store.requestDetails?.status, .built)
        XCTAssertEqual(store.requestDetails?.planSlug, "test123abc")
        XCTAssertEqual(store.todayLink?.slug, "test123abc", "it's today's shared plan now")
        XCTAssertEqual(store.todayLink?.suggestsSwaps, false, "no swap options the organizer hasn't seen")

        // Later changes update the page as usual, without the request: nothing goes out twice.
        try await Task.sleep(for: .milliseconds(200))
        let afterSettling = await sharing.published
        XCTAssertEqual(afterSettling.count, 1)

        // Friends' link opens it now: Undo would put the old plan there (GroupBuildUndoTests).
        XCTAssertNil(store.undo)
        XCTAssertNotEqual(store.today.stops.map(\.id), before)
    }

    func testOnlyTodaysLinkCanBeBuilt() async throws {
        let (store, _) = try await requestedStore(on: Calendar.current.date(byAdding: .day, value: 2, to: elevenAM)!)
        let link = try XCTUnwrap(store.planRequest)
        guard case .ready(let plan)? = store.groupInputs(organizer: store.organizerInputs(for: link), leftOut: []) else {
            return XCTFail("expected a plan")
        }
        let before = store.today.stops.map(\.id)
        XCTAssertNil(store.previewGroupPlan(plan, now: elevenAM))
        XCTAssertNil(store.buildGroupPlan(plan, now: elevenAM))
        XCTAssertEqual(store.today.stops.map(\.id), before)
    }

    func testStarredPlacesAreKeptWhenTheBudgetIsTight() async throws {
        // On $8 not everything fits: Maya's one starred place stays in.
        let (store, requests) = try await requestedStore()
        await requests.setAnswers([answer("Maya", budget: 8, 12, 20, stars: [SampleData.littleIslandPost.id])])
        await store.refreshPlanRequest(force: true)
        let link = try XCTUnwrap(store.planRequest)
        guard case .ready(let plan)? = store.groupInputs(organizer: store.organizerInputs(for: link), leftOut: []) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.budget, 8)
        let outcome = try XCTUnwrap(store.previewGroupPlan(plan, now: elevenAM))
        XCTAssertTrue(outcome.stops.contains { $0.sourcePostID == SampleData.littleIslandPost.id })
        XCTAssertLessThanOrEqual(outcome.cost, 8)
    }

    // MARK: - Helpers

    private var places: [SavedPost] {
        [SampleData.highLinePost, SampleData.tacosPost, SampleData.levainPost, SampleData.littleIslandPost]
    }

    /// 11 AM today, before the range starts.
    private var elevenAM: Date {
        Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
    }

    private func draft(on day: Date? = nil) -> PlanRequestDraft {
        PlanRequestDraft(posts: places, day: day ?? elevenAM, start: ClockTime(12), end: ClockTime(20),
                         answersBy: elevenAM.addingTimeInterval(3600))
    }

    private func makeStore(sharing: FakePlanSharing = FakePlanSharing()) -> PlanditStore {
        let store = PlanditStore(today: SampleData.dayPlan, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        return store
    }

    private func requestedStore(on day: Date? = nil) async throws -> (PlanditStore, RecordingRequests) {
        let store = makeStore()
        let requests = RecordingRequests()
        store.requestClient = requests
        try await store.createPlanRequest(draft(on: day), answersBy: elevenAM.addingTimeInterval(3600))
        return (store, requests)
    }

    private func answer(_ name: String, budget: Int, _ from: Int, _ until: Int, stars: [UUID] = []) -> GroupAnswer {
        GroupAnswer(id: UUID(), name: name, budget: budget, freeFrom: ClockTime(from), freeUntil: ClockTime(until),
                    stars: stars, createdAt: Date(), updatedAt: Date())
    }

    private func requestJSON(slug: String) -> String {
        """
        {"slug": "\(slug)", "url": "https://plandit.app/g/\(slug)", "status": "open", "places": [],
         "day": "2026-11-22", "windowStart": "12:00", "windowEnd": "20:00", "timeZone": "America/New_York",
         "answersBy": "2026-11-22T17:00:00Z", "planSlug": null, "createdAt": "2026-11-22T14:00:00Z", "answers": []}
        """
    }

    private func waitUntilHeld(_ requests: RecordingRequests) async throws {
        for _ in 0..<200 {
            if await requests.isHolding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the request never went out")
    }

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: URL(string: "https://api.example")!, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }
}
