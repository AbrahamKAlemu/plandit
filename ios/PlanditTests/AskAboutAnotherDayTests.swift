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
