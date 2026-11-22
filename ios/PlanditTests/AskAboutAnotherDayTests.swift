import XCTest
@testable import Plandit

/// "Ask about another day" goes by what the server says now (review R6), and the status line after
/// the built plan stopped being shared (review R7).
@MainActor final class AskAboutAnotherDayTests: XCTestCase {
    private typealias F = AskFriendsFixtures

    override func setUp() {
        super.setUp()
        PlanditStore.requestRefreshInterval = 10
    }

    // R6
    func testALinkBuiltOnAnotherPhoneIsForgottenNotDeleted() async throws {
        let (store, requests) = try await F.requestedStore()
        // Built on the other phone; this one hasn't read that yet.
        await requests.setStatus(.built, planSlug: "plan1")
        let kind = try await store.discardKind()
        XCTAssertEqual(kind, .forget)
        try await store.discardPlanRequest(kind)
        XCTAssertNil(store.planRequest)
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, [], "friends' link keeps opening the plan")
    }

    // R6
    func testALinkBuiltHereButNeverSharedIsDeleted() async throws {
        let (store, requests) = try await F.requestedStore()
        await requests.setAnswers([F.answer("Maya", budget: 20, 13, 18)])
        await store.refreshPlanRequest(force: true)
        store.buildGroupPlan(try XCTUnwrap(F.plan(store)), now: F.elevenAM)
        XCTAssertNotNil(store.planRequest?.builtPlanID)
        // Sharing it failed, so the server still has it open.
        let kind = try await store.discardKind()
        XCTAssertEqual(kind, .delete)
        try await store.discardPlanRequest(kind)
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, ["req1"])
        XCTAssertNil(store.planRequest)
    }

    // R6
    func testAClosedLinkWithoutAPlanIsDeleted() async throws {
        let (store, requests) = try await F.requestedStore()
        await requests.setStatus(.closed)
        let kind = try await store.discardKind()
        XCTAssertEqual(kind, .delete)
    }

    // R6
    func testALinkTheServerNoLongerHasIsForgotten() async throws {
        let (store, requests) = try await F.requestedStore()
        await requests.setGone()
        let kind = try await store.discardKind()
        XCTAssertEqual(kind, .forget)
    }

    // R6
    func testWhenTheServerCantBeReachedTheLinkStays() async throws {
        let (store, requests) = try await F.requestedStore()
        await requests.failNext()
        do {
            _ = try await store.discardKind()
            XCTFail("it can't tell whether the link opens a plan")
        } catch {}
        XCTAssertNotNil(store.planRequest, "never forgotten without saying so")
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, [])
    }

    // Round 3, R2: a slow read from "Ask about another day" can't bring back an answer removed meanwhile.
    func testASlowCheckDoesNotBringBackARemovedAnswer() async throws {
        let (store, requests) = try await F.requestedStore()
        let maya = F.answer("Maya", budget: 20, 13, 18)
        await requests.setAnswers([maya, F.answer("Jordan", budget: 30, 12, 17)])
        await store.refreshPlanRequest(force: true)
        await requests.holdNext()
        let check = Task { try await store.discardKind() }
        for _ in 0..<200 { if await requests.isHolding { break }; try await Task.sleep(for: .milliseconds(10)) }
        try await store.removeRequestAnswer(maya.id)
        await requests.release()
        let kind = try await check.value
        XCTAssertEqual(kind, .delete, "it still decides by what the server said")
        XCTAssertEqual(store.requestDetails?.answers.map(\.name), ["Jordan"], "Maya's removed answer came back")
    }

    // Round 3, R3: built on another phone between the check and the confirmation: forgotten, not deleted.
    func testALinkBuiltElsewhereAfterTheCheckIsNotDeleted() async throws {
        let (store, requests) = try await F.requestedStore()
        let kind = try await store.discardKind()
        XCTAssertEqual(kind, .delete)
        // While the organizer reads "Delete this link?", the other phone builds the plan.
        await requests.setStatus(.built, planSlug: "plan1")
        try await store.discardPlanRequest(kind)
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, [], "friends' link keeps opening the plan")
        XCTAssertNil(store.planRequest, "the app lets go of it")
    }

    // Round 3, R3: the second check can't be read: nothing is deleted, and the link stays.
    func testWhenTheSecondCheckFailsNothingIsDeleted() async throws {
        let (store, requests) = try await F.requestedStore()
        let kind = try await store.discardKind()
        await requests.failNext()
        do {
            try await store.discardPlanRequest(kind)
            XCTFail("it couldn't tell whether the link opens a plan now")
        } catch {}
        let deleted = await requests.deleted
        XCTAssertEqual(deleted, [])
        XCTAssertNotNil(store.planRequest)
    }

    // R7
    func testTheStatusLineAfterTheBuiltPlanStopsBeingShared() {
        let link = PlanRequestLink(slug: "req1", url: URL(string: "https://plandit.app/g/req1")!, day: "2026-11-22",
                                   windowStart: "12:00", windowEnd: "20:00", timeZone: "America/New_York",
                                   answersBy: Date(), placeIDs: [], builtPlanID: nil)
        var details = PlanRequest(slug: "req1", url: link.url, status: .built, placeIDs: [], answersBy: Date(),
                                  planSlug: "plan1", answers: [])
        XCTAssertEqual(AskFriendsText.status(link, details, now: Date()), "Done. The link now opens your plan.")
        details.planSlug = nil
        XCTAssertEqual(AskFriendsText.status(link, details, now: Date()),
                       "Your plan isn't shared anymore, so friends' link shows it's closed.")
    }
}
