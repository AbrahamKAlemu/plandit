import XCTest
@testable import Plandit

/// Undo after "Build our plan" (review M1, M2): it's offered only while the built plan isn't on
/// friends' link yet, and "Try again" never puts a plan on the link that isn't the one built.
@MainActor final class GroupBuildUndoTests: XCTestCase {
    private typealias F = AskFriendsFixtures

    override func setUp() {
        super.setUp()
        PlanditStore.shareUpdateDelay = .milliseconds(50)
        PlanditStore.requestRefreshInterval = 10
    }

    /// The DEBUG fake server (Maya and Jordan), with a link made and its answers read.
    private func fakeStore(_ sharing: FakePlanSharing) async throws -> PlanditStore {
        let store = F.makeStore(sharing: sharing)
        store.requestClient = FakePlanRequests(sharing: sharing, clashes: false)
        try await store.createPlanRequest(F.draft(), answersBy: F.elevenAM.addingTimeInterval(3600))
        await store.refreshPlanRequest(force: true)
        return store
    }

    // M1
    func testOnceThePlanIsOnTheLinkThereIsNoUndo() async throws {
        let sharing = FakePlanSharing()
        let store = try await fakeStore(sharing)
        let plan = try XCTUnwrap(F.plan(store))
        let built = try XCTUnwrap(store.buildGroupPlan(plan, now: F.elevenAM)).stops.map(\.id)
        try await store.shareGroupPlan()
        XCTAssertNil(store.undo, "Undo would put the old plan on the page friends' link opens")

        store.undoLastChange()
        try await Task.sleep(for: .milliseconds(400))
        let published = await sharing.published
        XCTAssertEqual(published.count, 1, "only the built plan went out")
        XCTAssertEqual(store.today.stops.map(\.id), built)
    }

    // M1, M2
    func testUndoBeforeThePlanIsOnTheLinkPutsTodayBack() async throws {
        let sharing = FakePlanSharing()
        let store = try await fakeStore(sharing)
        let before = store.today.stops.map(\.id)
        let plan = try XCTUnwrap(F.plan(store))
        store.buildGroupPlan(plan, now: F.elevenAM)
        // Sharing it failed: the plan is in Today but not on the link.
        XCTAssertTrue(store.groupPlanAwaitsLink)
        XCTAssertEqual(store.undo?.message, "Built our plan. It isn't on the link yet.")

        store.undoLastChange()
        XCTAssertEqual(store.today.stops.map(\.id), before)
        XCTAssertNil(store.planRequest?.builtPlanID)
        XCTAssertFalse(store.groupPlanAwaitsLink, "no Try again for a plan that's gone")
        do {
            try await store.shareGroupPlan()
            XCTFail("Try again put the undone plan on friends' link")
        } catch {}
        let published = await sharing.published
        XCTAssertEqual(published, [])

        // Build is offered again.
        XCTAssertNotNil(store.buildGroupPlan(plan, now: F.elevenAM))
        XCTAssertTrue(store.groupPlanAwaitsLink)
    }

    // M2
    func testTryAgainNeverSendsAPlanMadeAnotherWay() async throws {
        let sharing = FakePlanSharing()
        let store = try await fakeStore(sharing)
        let plan = try XCTUnwrap(F.plan(store))
        store.buildGroupPlan(plan, now: F.elevenAM)
        // The organizer makes a new plan in the planner instead; today's plan keeps its id.
        store.buildPlan(postIDs: [SampleData.levainPost.id], start: F.elevenAM, budget: 40, mode: .replace)
        XCTAssertFalse(store.groupPlanAwaitsLink)
        do {
            try await store.shareGroupPlan()
            XCTFail("Try again put a plan that wasn't built from the answers on friends' link")
        } catch {}
        let published = await sharing.published
        XCTAssertNil(published.last(where: { $0.request != nil }))
    }
}
