import XCTest
@testable import Plandit

final class UsageEventTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    @MainActor private final class Recorder {
        var events: [UsageEvent] = []
    }

    @MainActor private func makeStore(saved: [SavedPost] = []) -> (PlanditStore, Recorder) {
        let recorder = Recorder()
        let store = PlanditStore(
            today: .empty(for: .now, budget: 60), saved: saved, profile: SampleData.profile,
            pastPlans: [], visited: [], extractor: NoExtractor(), storage: nil,
            events: { recorder.events.append($0) }
        )
        return (store, recorder)
    }

    @MainActor func testSavingALinkEmitsLinkSavedOnce() throws {
        let (store, recorder) = makeStore()
        let url = URL(string: "https://www.tiktok.com/@someone/video/7400000000000000200")!
        _ = try store.save(url: url)
        _ = try store.save(url: url)
        XCTAssertEqual(recorder.events, [.linkSaved])
    }

    @MainActor func testConfirmingACandidateEmitsPlaceSaved() {
        let candidate = PlaceCandidate(id: "mapkit:levain", place: SampleData.levain, confidence: .high, reason: "match")
        let post = SavedPost(
            url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000201")!,
            platform: .tiktok, savedAt: .now, status: .needsConfirmation, candidates: [candidate]
        )
        let (store, recorder) = makeStore(saved: [post])
        XCTAssertFalse(store.confirm(postID: post.id, candidateID: "nope"))
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(store.confirm(postID: post.id, candidateID: candidate.id))
        XCTAssertEqual(recorder.events, [.placeSaved])
    }

    @MainActor func testBuildingAPlanWithStopsEmitsPlanBuilt() {
        let (store, recorder) = makeStore(saved: [SampleData.levainPost, SampleData.tacosPost])
        _ = store.buildPlan(postIDs: [], start: SampleData.at(10), budget: 50, mode: .replace)
        XCTAssertTrue(recorder.events.isEmpty, "an empty plan is not the core action")
        _ = store.buildPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(10), budget: 50, mode: .replace)
        XCTAssertEqual(recorder.events, [.planBuilt])
    }

    @MainActor func testAddingToTodayEmitsPlanBuilt() {
        let (store, recorder) = makeStore(saved: [SampleData.levainPost])
        XCTAssertNotNil(store.addToToday(SampleData.levainPost.id))
        XCTAssertNil(store.addToToday(SampleData.levainPost.id))
        XCTAssertEqual(recorder.events, [.planBuilt])
    }

    func testEventNamesMatchTheAPI() {
        XCTAssertEqual(UsageEvent.allCases.map(\.rawValue), ["plan_built", "link_saved", "place_saved"])
    }

    func testEventClientPostsNameAndTime() async throws {
        let transport = FakeTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/me/events/")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["name"], "plan_built")
            XCTAssertEqual(body["occurred_at"], "2027-01-15T08:00:00Z")
            return (201, TestJSON.object(["name": "plan_built", "occurred_at": "2027-01-15T08:00:00Z"]))
        }
        let api = PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
        try await UsageEventClient(api: api).send(.planBuilt, occurredAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDeleteAccountAcceptsOnly204() async throws {
        let transport = FakeTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/me/")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (502, TestJSON.object(["detail": "Could not delete the account."]))
        }
        let api = PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
        do {
            try await api.deleteAccount()
            XCTFail("expected a status error")
        } catch {
            XCTAssertEqual(error as? APIError, .status(502))
        }
        transport.respond { _ in (204, Data()) }
        try await api.deleteAccount()
    }
}
