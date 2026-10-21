import XCTest
@testable import Plandit

final class FixturePlaceExtractorTests: XCTestCase {
    func testKnownEvidenceReturnsMatchingPlaceFirst() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        let url = URL(string: "https://www.tiktok.com/@creator/video/123")!

        let result = try await extractor.extract(
            from: url,
            sharedText: "You have to try Levain Bakery on the Upper West Side"
        )

        XCTAssertEqual(result.candidates.first?.place.name, "Levain Bakery")
        XCTAssertLessThanOrEqual(result.candidates.count, 3)
    }

    func testUnknownEvidenceNeedsMoreDetails() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!

        let result = try await extractor.extract(from: url, sharedText: nil)

        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testTikTokMetadataFallsBackToPlaceSearch() async throws {
        let candidate = PlaceCandidate(
            id: "mapkit:joes-pizza",
            place: Place(
                name: "Joe's Pizza",
                category: .food,
                neighborhood: "Greenwich Village",
                address: "7 Carmine St, New York, NY",
                latitude: 40.7306,
                longitude: -74.0027
            ),
            confidence: .medium,
            reason: "Apple Maps matched the caption or approved text"
        )
        let extractor = FixturePlaceExtractor(
            metadataProvider: StubMetadataProvider(
                metadata: SocialMetadata(
                    title: "You have to try Joe's Pizza in Greenwich Village",
                    authorHandle: "@creator",
                    thumbnailURL: nil
                )
            ),
            placeSearcher: StubPlaceSearcher(candidates: [candidate])
        )

        let result = try await extractor.extract(
            from: URL(string: "https://www.tiktok.com/@creator/video/123")!,
            sharedText: nil
        )

        XCTAssertEqual(result.candidates, [candidate])
        XCTAssertEqual(result.caption, "You have to try Joe's Pizza in Greenwich Village")
    }

    func testQueryBuilderPrioritizesPlaceAfterCue() {
        let queries = PlaceQueryBuilder.queries(
            from: "Best slice in NYC at Joe's Pizza #foodtok"
        )

        XCTAssertEqual(queries.first, "Joe's Pizza foodtok")
    }
}

private struct StubMetadataProvider: SocialMetadataProviding {
    let metadata: SocialMetadata?

    func metadata(for url: URL) async throws -> SocialMetadata? {
        metadata
    }
}

private struct StubPlaceSearcher: PlaceSearching {
    let candidates: [PlaceCandidate]

    func search(evidence: String) async throws -> [PlaceCandidate] {
        candidates
    }
}
