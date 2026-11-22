import UniformTypeIdentifiers
import XCTest
@testable import Plandit

/// JN-1 through the share sheet: an invite link shared from Safari (or in a message's text) isn't
/// saved as a place. The extension leaves it in the App Group for the app (`JoinGroupRoutingTests`).
final class InviteHandoffTests: XCTestCase {
    private let link = URL(string: "https://plandit.app/j/AbC-dEf_GhIjKlMnOpQrSt")!
    private let token = "AbC-dEf_GhIjKlMnOpQrSt"

    override func setUp() async throws {
        await MainActor.run { Self.clearInboxes() }
    }

    override func tearDown() async throws {
        await MainActor.run { Self.clearInboxes() }
    }

    @MainActor private static func clearInboxes() {
        for share in ShareInbox.pending() { ShareInbox.acknowledge(share.id) }
        _ = InviteInbox.take()
    }

    @MainActor private func share(_ providers: [NSItemProvider], contentText: [String] = []) async -> ShareFlow {
        let flow = ShareFlow(intake: ShareIntake(mediaStore: nil))
        await flow.start(providers: providers, contentText: contentText)
        return flow
    }

    // MARK: - The App Group slot

    @MainActor func testAHeldInviteIsTakenOnceThenGone() {
        InviteInbox.hold(token)

        XCTAssertEqual(InviteInbox.take(), token)
        XCTAssertNil(InviteInbox.take())
    }

    @MainActor func testTheLatestInviteWins() {
        InviteInbox.hold(token)
        InviteInbox.hold("fake-invite-jordans-day")

        XCTAssertEqual(InviteInbox.take(), "fake-invite-jordans-day")
        XCTAssertNil(InviteInbox.take())
    }

    @MainActor func testNothingHeld() {
        XCTAssertNil(InviteInbox.take())
    }

    /// UI tests: `-seedInvite <token>` holds one, as if it had come through the share sheet.
    @MainActor func testSeedingFromLaunchArgumentsHoldsTheToken() {
        InviteInbox.seedFromLaunchArguments(["Plandit", "-seedInvite", "fake-invite-jordans-day"], force: true)
        XCTAssertEqual(InviteInbox.take(), "fake-invite-jordans-day")

        InviteInbox.seedFromLaunchArguments(["Plandit", "-skipAuth"], force: true)
        XCTAssertNil(InviteInbox.take())
    }

    // MARK: - The share sheet

    @MainActor func testSafariSharingAnInviteLinkHandsItToTheAppInsteadOfSavingIt() async {
        let flow = await share([NSItemProvider(object: link as NSURL)])

        XCTAssertEqual(flow.state, .invite)
        XCTAssertTrue(ShareInbox.pending().isEmpty, "not saved as a place")
        XCTAssertEqual(InviteInbox.take(), token)
    }

    @MainActor func testAnInviteLinkInSharedText() async {
        let text = "Let's plan Saturday together! \(link.absoluteString)"
        let flow = await share([NSItemProvider(object: text as NSString)])

        XCTAssertEqual(flow.state, .invite)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertEqual(InviteInbox.take(), token)
    }

    @MainActor func testAnInviteLinkInTheShareSheetsOwnText() async {
        let flow = await share([], contentText: ["Join us \(link.absoluteString)/"])

        XCTAssertEqual(flow.state, .invite)
        XCTAssertEqual(InviteInbox.take(), token)
    }

    @MainActor func testTikTokLinksAreStillSavedAndHoldNoInvite() async {
        let url = URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!
        let flow = await share([NSItemProvider(object: url as NSURL)])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .tiktok, creator: "@nycbites")))
        XCTAssertEqual(ShareInbox.pending().count, 1)
        XCTAssertNil(InviteInbox.take())
    }

    @MainActor func testSharedPlanAndFriendsInputLinksAreStillNotSaved() async {
        for page in ["https://plandit.app/p/\(token)", "https://plandit-api.onrender.com/g/Ab12Cd34"] {
            let flow = await share([NSItemProvider(object: URL(string: page)! as NSURL)])

            XCTAssertEqual(flow.state, .problem(.unsupportedLink), page)
            XCTAssertTrue(ShareInbox.pending().isEmpty, page)
            XCTAssertNil(InviteInbox.take(), page)
        }
    }

    @MainActor func testTheSheetSaysToOpenPlanditToJoin() {
        XCTAssertEqual(ShareFlow.inviteTitle, "Open Plandit to join")
        XCTAssertFalse(ShareFlow.inviteMessage.isEmpty)
        for word in ["discover", "explore", "itinerary", "cheap", "hidden gems", "curated", "seamless", "elevate", "AI-powered"] {
            XCTAssertFalse(ShareFlow.inviteMessage.lowercased().contains(word.lowercased()), word)
            XCTAssertFalse(ShareFlow.inviteTitle.lowercased().contains(word.lowercased()), word)
        }
    }
}
