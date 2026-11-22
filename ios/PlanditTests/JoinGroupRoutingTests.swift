import XCTest
@testable import Plandit

/// The router's side of joining: an invite the share sheet left opens the join sheet once, the
/// next time the app becomes active, and is then forgotten; after joining, Today opens on the
/// group (the seam with Today: `groupPlanToOpen`).
final class JoinGroupRoutingTests: XCTestCase {
    private let token = "AbC-dEf_GhIjKlMnOpQrSt"

    override func setUp() async throws {
        await MainActor.run { _ = InviteInbox.take() }
    }

    override func tearDown() async throws {
        await MainActor.run { _ = InviteInbox.take() }
    }

    @MainActor func testTheAppOpensAHeldInviteOnceThenForgetsIt() {
        let router = SheetRouter()
        InviteInbox.hold(token)

        router.openPendingInvite()
        let first = router.inviteToJoin
        XCTAssertEqual(first?.token, token)
        XCTAssertNil(InviteInbox.take(), "cleared once taken")

        router.inviteToJoin = nil
        router.openPendingInvite()
        XCTAssertNil(router.inviteToJoin, "not opened a second time")
    }

    @MainActor func testNothingHeldOpensNothing() {
        let router = SheetRouter()
        router.openPendingInvite()
        XCTAssertNil(router.inviteToJoin)
    }

    @MainActor func testTheSameLinkPastedAgainOpensAFreshSheet() {
        let router = SheetRouter()
        router.join(invite: token)
        let first = router.inviteToJoin
        router.join(invite: token)

        XCTAssertEqual(router.inviteToJoin?.token, token)
        XCTAssertNotEqual(router.inviteToJoin?.id, first?.id)
    }

    /// The seam with Today: after joining, the sheets close and Today opens on that group.
    @MainActor func testOpeningAJoinedGroupClosesTheSheetAndShowsToday() {
        let router = SheetRouter()
        router.tab = .saved
        router.todayPath = [UUID()]
        router.join(invite: token)
        let group = UUID()

        router.openGroupPlan(group)

        XCTAssertNil(router.inviteToJoin)
        XCTAssertEqual(router.groupPlanToOpen, group)
        XCTAssertEqual(router.tab, .today)
        XCTAssertTrue(router.todayPath.isEmpty)
    }
}
