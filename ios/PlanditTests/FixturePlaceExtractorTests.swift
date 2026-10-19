import XCTest
@testable import Plandit

final class FixturePlaceExtractorTests: XCTestCase {
    func testKnownEvidenceReturnsMatchingPlaceFirst() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil)
        let url = URL(string: "https://www.tiktok.com/@creator/video/123")!

        let result = try await extractor.extract(
            from: url,
            sharedText: "You have to try Levain Bakery on the Upper West Side"
        )

        XCTAssertEqual(result.candidates.first?.place.name, "Levain Bakery")
        XCTAssertLessThanOrEqual(result.candidates.count, 3)
    }

    func testUnknownEvidenceNeedsMoreDetails() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil)
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!

        let result = try await extractor.extract(from: url, sharedText: nil)

        XCTAssertTrue(result.candidates.isEmpty)
    }
}
