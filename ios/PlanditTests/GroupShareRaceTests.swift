import XCTest
@testable import Plandit

/// Undo and other changes while "Build our plan" is still putting the plan on friends' link
/// (round 3 review, R1): the plan the link opens is always the one built, never the one before.
@MainActor final class GroupShareRaceTests: XCTestCase {
    private typealias F = AskFriendsFixtures

    override func setUp() {
        super.setUp()
        PlanditStore.shareUpdateDelay = .milliseconds(50)
        PlanditStore.requestRefreshInterval = 10
    }

    /// A link with Maya's answer read, on a server that holds publishes.
    private func makeStore(_ sharing: SlowWakeSharing) async throws -> PlanditStore {
        let store = F.makeStore()
        store.sharing = sharing
        let requests = RecordingRequests()
        store.requestClient = requests
        try await store.createPlanRequest(F.draft(), answersBy: F.elevenAM.addingTimeInterval(3600))
        await requests.setAnswers([F.answer("Maya", budget: 20, 13, 18)])
        await store.refreshPlanRequest(force: true)
        return store
    }

    // R1 (the reviewer's test): the planner was swiped down and Undo tapped while the share was out.
    func testUndoWhileTheShareIsOutNeverPutsTheOldPlanOnTheLink() async throws {
        let sharing = SlowWakeSharing()
        let store = try await makeStore(sharing)
        let before = store.today.stops.map(\.id)
        let built = try XCTUnwrap(store.buildGroupPlan(try XCTUnwrap(F.plan(store)), now: F.elevenAM)).stops.map(\.id)
        let share = Task { try await store.shareGroupPlan() }
        try await sharing.waitUntilHolding()
        XCTAssertFalse(store.canUndo, "the undo bar doesn't offer Undo while the share is out")
        store.undoLastChange()
        XCTAssertEqual(store.today.stops.map(\.id), built, "Undo is refused while the share is out")

        sharing.release()
        try await share.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(sharing.published.contains { $0.stops.map(\.id) == before },
                       "the pre-build plan reached the page friends' link opens")
        XCTAssertEqual(sharing.published.last?.stops.map(\.id), built)
        XCTAssertNil(store.undo)
    }

    // R1 (b): a page update was out, so the share waited its turn, and Today changed meanwhile.
    func testAPlanChangedWhileTheShareWaitedIsNotPutOnFriendsLink() async throws {
        let sharing = SlowWakeSharing()
        sharing.holds = false
        let store = try await makeStore(sharing)
        try await store.shareToday(showPrices: true, note: "")
        sharing.holds = true
        store.buildGroupPlan(try XCTUnwrap(F.plan(store)), now: F.elevenAM)
        // The page update for the built plan is out and slow.
        try await sharing.waitUntilHolding()
        let share = Task { try await store.shareGroupPlan() }
        try await Task.sleep(for: .milliseconds(50))
        // The organizer makes another plan in the planner while it waits.
        store.buildPlan(postIDs: [SampleData.levainPost.id], start: F.elevenAM, budget: 40, mode: .replace)
        sharing.release()
        do {
            try await share.value
            XCTFail("the share went ahead with a plan that wasn't built from the answers")
        } catch {}
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sharing.published.filter { $0.request != nil }.count, 0,
                       "friends' link never opens a plan that wasn't built from their answers")
        XCTAssertNotEqual(store.requestDetails?.status, .built)
    }

    // R1: if the share fails after Undo was refused, Undo is offered again and works.
    func testWhenTheShareFailsUndoIsOfferedAgain() async throws {
        let sharing = SlowWakeSharing()
        sharing.failsOnRelease = true
        let store = try await makeStore(sharing)
        let before = store.today.stops.map(\.id)
        store.buildGroupPlan(try XCTUnwrap(F.plan(store)), now: F.elevenAM)
        let share = Task { try await store.shareGroupPlan() }
        try await sharing.waitUntilHolding()
        store.undoLastChange()
        sharing.release()
        do {
            try await share.value
            XCTFail("the server never answered")
        } catch {}
        XCTAssertTrue(store.canUndo)
        store.undoLastChange()
        XCTAssertEqual(store.today.stops.map(\.id), before)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(sharing.published.filter { $0.request != nil }.count, 0)
    }
}
