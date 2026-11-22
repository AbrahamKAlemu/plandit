import XCTest
@testable import Plandit

/// JN-1: which links are group plan invites (`…/j/<token>`), for "Add a link" and the share sheet.
/// Every other link must keep going where it went before: `/p/` and `/g/` pages, TikTok and
/// Instagram posts, and anything else.
final class InviteLinkTests: XCTestCase {
    /// 22 URL-safe characters, as the server makes them (`secrets.token_urlsafe(16)`).
    private let token = "AbC-dEf_GhIjKlMnOpQrSt"

    @MainActor private func token(_ text: String) -> String? {
        InviteLink.token(in: text)
    }

    // MARK: - Accepted

    @MainActor func testTheSiteAndItsWWWHost() {
        XCTAssertEqual(token("https://plandit.app/j/\(token)"), token)
        XCTAssertEqual(token("https://www.plandit.app/j/\(token)"), token)
    }

    @MainActor func testTheAPIHostThatMakesLinksUntilTheSiteForwardsThem() {
        XCTAssertEqual(token("https://plandit-api.onrender.com/j/\(token)"), token)
    }

    @MainActor func testATrailingSlashQueryOrFragment() {
        XCTAssertEqual(token("https://plandit.app/j/\(token)/"), token)
        XCTAssertEqual(token("https://plandit.app/j/\(token)?utm_source=messages"), token)
        XCTAssertEqual(token("https://plandit.app/j/\(token)#join"), token)
        XCTAssertEqual(token("https://plandit.app/j/\(token)/?a=1#b"), token)
    }

    @MainActor func testHostCaseSchemeAndDefaultPortDontMatter() {
        XCTAssertEqual(token("https://Plandit.App/j/\(token)"), token)
        XCTAssertEqual(token("http://plandit.app/j/\(token)"), token)
        XCTAssertEqual(token("https://plandit.app:443/j/\(token)"), token)
    }

    @MainActor func testATypedLinkWithoutHTTPS() {
        XCTAssertEqual(token("plandit.app/j/\(token)"), token)
        XCTAssertEqual(token("www.plandit.app/j/\(token)/"), token)
    }

    @MainActor func testSpacesAndNewlinesAroundAPastedLink() {
        XCTAssertEqual(token("  https://plandit.app/j/\(token)\n"), token)
    }

    @MainActor func testTheLinkInsideSharedText() {
        XCTAssertEqual(token("Let's plan Saturday together! https://plandit.app/j/\(token) see you there"), token)
        XCTAssertEqual(token("Join here: https://plandit.app/j/\(token)."), token)
        XCTAssertEqual(token("(https://plandit.app/j/\(token))"), token)
        XCTAssertEqual(token("\u{201C}https://plandit.app/j/\(token)\u{201D}"), token)
    }

    @MainActor func testTheInviteWinsOverAnotherLinkBeforeIt() {
        XCTAssertEqual(token("Get the app at https://plandit.app then open https://plandit.app/j/\(token)"), token)
    }

    @MainActor func testDashesAndUnderscoresAtEitherEnd() {
        XCTAssertEqual(token("https://plandit.app/j/-bcdefghijklmnopqrstu_"), "-bcdefghijklmnopqrstu_")
        XCTAssertEqual(token("Join: https://plandit.app/j/abcdefghijklmnopqrstu- ok"), "abcdefghijklmnopqrstu-")
    }

    /// The fake server's tokens are a character longer than the server's; the server is the judge
    /// of which tokens work, so a longer one is let through to ask it.
    @MainActor func testTheFakeServersJoinableLink() {
        XCTAssertEqual(token("https://plandit.app/j/\(FakeGroupPlanServer.joinableToken)"), FakeGroupPlanServer.joinableToken)
        XCTAssertEqual(token("https://plandit.app/j/fake-invite-for-tests-12"), "fake-invite-for-tests-12")
    }

    @MainActor func testAURL() {
        XCTAssertEqual(InviteLink.token(in: URL(string: "https://plandit.app/j/\(token)/")!), token)
        XCTAssertNil(InviteLink.token(in: URL(string: "https://plandit.app/p/\(token)")!))
    }

    // MARK: - Rejected

    @MainActor func testOtherPathsOnPlanditsHosts() {
        for path in ["", "/", "/j", "/j/", "/privacy", "/support", "/x/\(token)", "/j/\(token)/more", "/J/\(token)",
                     "/j//\(token)", "/api/group-plans/invites/\(token)/", "/static/shares/\(token)"] {
            XCTAssertNil(token("https://plandit.app\(path)"), path)
        }
    }

    @MainActor func testSharedPlanAndFriendsInputLinksStayAsTheyAre() {
        XCTAssertNil(token("https://plandit.app/p/\(token)"))
        XCTAssertNil(token("https://plandit-api.onrender.com/p/Ab12Cd34"))
        XCTAssertNil(token("https://plandit.app/g/\(token)"))
        XCTAssertNil(token("https://plandit-api.onrender.com/g/Ab12Cd34/"))
    }

    @MainActor func testTikTokAndInstagramLinks() {
        XCTAssertNil(token("https://www.tiktok.com/@nycbites/video/7400000000000000001"))
        XCTAssertNil(token("https://vm.tiktok.com/ZMabcdef/"))
        XCTAssertNil(token("https://www.instagram.com/reel/DHZYjjnPKez/?igsh=abc"))
        XCTAssertNil(token("Best tacos https://www.tiktok.com/@cheapeatsnyc/video/7400000000000000202"))
    }

    @MainActor func testOtherHosts() {
        XCTAssertNil(token("https://example.com/j/\(token)"))
        XCTAssertNil(token("https://plandit.app.example.com/j/\(token)"))
        XCTAssertNil(token("https://notplandit.app/j/\(token)"))
        XCTAssertNil(token("https://tiktok.com/j/\(token)"))
    }

    @MainActor func testMalformedTokens() {
        for bad in ["abc", "short-token-15c", String(repeating: "a", count: 65), "abcdefghij.klmnopqrstuv",
                    "abcdefghij!klmnopqrstuv", "abcdefghij%20klmnopqrstu", "abcdefghij%2Fklmnopqrstu",
                    "abcdefghij~klmnopqrstuv"] {
            XCTAssertNil(token("https://plandit.app/j/\(bad)"), bad)
        }
    }

    @MainActor func testCredentialsOtherPortsAndOtherSchemes() {
        XCTAssertNil(token("https://someone@plandit.app/j/\(token)"))
        XCTAssertNil(token("https://plandit.app:8443/j/\(token)"))
        XCTAssertNil(token("ftp://plandit.app/j/\(token)"))
        XCTAssertNil(token("plandit://j/\(token)"))
    }

    @MainActor func testTextWithoutALink() {
        XCTAssertNil(token(""))
        XCTAssertNil(token("   "))
        XCTAssertNil(token("Saturday at 3?"))
        XCTAssertNil(token(token))
    }

    /// The old path never took these either, so routing invites first changes nothing else.
    @MainActor func testInviteLinksWereNeverSocialPosts() {
        XCTAssertThrowsError(try SupportedSocialURL(URL(string: "https://plandit.app/j/\(token)")!))
    }
}
