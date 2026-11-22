import XCTest
@testable import Plandit

/// Review M3: until the first read of the answers succeeds there's no plan to preview or build.
/// After a relaunch the link comes back from the snapshot, but the answers don't.
@MainActor final class GroupAnswersFetchTests: XCTestCase {
    private typealias F = AskFriendsFixtures

    override func setUp() {
        super.setUp()
        PlanditStore.requestRefreshInterval = 10
    }

    private func relaunched(after store: PlanditStore, requests: RecordingRequests) -> PlanditStore {
        let relaunched = PlanditStore(snapshot: store.snapshot)
        relaunched.sharing = FakePlanSharing()
        relaunched.requestClient = requests
        return relaunched
    }

    func testBeforeTheFirstReadThereIsNoPlan() async throws {
        let (first, requests) = try await F.requestedStore()
        await requests.setAnswers([F.answer("Maya", budget: 20, 13, 18)])
        let store = relaunched(after: first, requests: requests)
        XCTAssertNil(store.requestDetails)
        XCTAssertNil(F.plan(store), "a plan from the organizer's inputs alone would leave Maya out")

        await store.refreshPlanRequest(force: true)
        XCTAssertEqual(F.plan(store)?.budget, 20)
        XCTAssertFalse(store.requestFetchFailed)
    }

    func testAFailedFirstReadSaysSoAndCanBeTriedAgain() async throws {
        let (first, requests) = try await F.requestedStore()
        await requests.setAnswers([F.answer("Maya", budget: 20, 13, 18)])
        let store = relaunched(after: first, requests: requests)
        await requests.failNext()
        await store.refreshPlanRequest()
        XCTAssertTrue(store.requestFetchFailed)
        XCTAssertNil(F.plan(store))
        XCTAssertNotNil(store.planRequest, "the link stays")

        await store.refreshPlanRequest(force: true)
        XCTAssertFalse(store.requestFetchFailed)
        XCTAssertEqual(F.plan(store)?.budget, 20)
    }

    func testALaterFailedReadKeepsWhatWasShownWithoutAnError() async throws {
        let (store, requests) = try await F.requestedStore()
        await requests.failNext()
        await store.refreshPlanRequest(force: true)
        XCTAssertFalse(store.requestFetchFailed, "the answers read before are still shown")
        XCTAssertNotNil(store.requestDetails)
    }
}
