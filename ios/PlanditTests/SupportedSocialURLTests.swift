import XCTest
@testable import Plandit

final class SupportedSocialURLTests: XCTestCase {
    func testAcceptsAndCanonicalizesTikTokVideo() throws {
        let input = URL(string: "https://www.tiktok.com/@creator/video/123456789?is_from_webapp=1#share")!

        let supported = try SupportedSocialURL(input)

        XCTAssertEqual(supported.platform, .tiktok)
        XCTAssertEqual(supported.canonicalURL.absoluteString, "https://www.tiktok.com/@creator/video/123456789")
    }

    func testAcceptsInstagramReel() throws {
        let input = URL(string: "https://instagram.com/reel/ABC_123/?igsh=test")!

        let supported = try SupportedSocialURL(input)

        XCTAssertEqual(supported.platform, .instagram)
        XCTAssertEqual(supported.canonicalURL.absoluteString, "https://instagram.com/reel/ABC_123")
    }

    func testRejectsUnsupportedAndDeceptiveHosts() {
        XCTAssertThrowsError(try SupportedSocialURL(URL(string: "https://tiktok.com.example.com/@a/video/123")!))
        XCTAssertThrowsError(try SupportedSocialURL(URL(string: "https://example.com/reel/ABC")!))
        XCTAssertThrowsError(try SupportedSocialURL(URL(string: "http://www.tiktok.com/@a/video/123")!))
    }
}
