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

    func testSearchOnlyEvidenceIsNotReturnedAsPersistableCaption() async throws {
        let candidate = PlaceCandidate(
            id: "mapkit:chubby-bowls",
            place: SampleData.losTacos,
            confidence: .medium,
            reason: "Apple Maps matched the caption or approved text"
        )
        let evidence = "Come with me to check out Chubby Bowls at 809 Broadway"
        let extractor = FixturePlaceExtractor(
            metadataProvider: StubMetadataProvider(
                metadata: SocialMetadata(
                    title: nil,
                    authorHandle: "@creator",
                    thumbnailURL: nil,
                    searchEvidence: evidence
                )
            ),
            placeSearcher: StubPlaceSearcher(
                candidates: [candidate],
                expectedEvidence: evidence
            )
        )

        let result = try await extractor.extract(
            from: URL(string: "https://www.tiktok.com/@creator/video/123")!,
            sharedText: nil
        )

        XCTAssertEqual(result.candidates, [candidate])
        XCTAssertNil(result.caption)
    }

    func testMetadataProviderFallsBackAfterPrimaryFailure() async throws {
        let expected = SocialMetadata(
            title: "Fallback caption",
            authorHandle: "@creator",
            thumbnailURL: nil
        )
        let provider = FallbackSocialMetadataProvider(
            primary: FailingMetadataProvider(),
            fallback: StubMetadataProvider(metadata: expected)
        )

        let metadata = try await provider.metadata(
            for: URL(string: "https://www.tiktok.com/@creator/video/123")!
        )

        XCTAssertEqual(metadata?.title, expected.title)
    }

    func testQueryBuilderPrioritizesPlaceAfterCue() {
        let queries = PlaceQueryBuilder.queries(
            from: "Best slice in NYC at Joe's Pizza #foodtok"
        )

        XCTAssertEqual(queries.first, "Joe's Pizza foodtok")
    }

    func testQueryBuilderExtractsPlaceAfterCheckOut() {
        let queries = PlaceQueryBuilder.queries(
            from: "Come with me to check out Chubby Bowls in Union Square! Great food."
        )

        XCTAssertEqual(queries.first, "Chubby Bowls in Union Square")
    }

    func testQueryBuilderPrioritizesCaptionPlaceAndAddressBlock() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            NYC is too expensive is back! $7 chicken bowl at this Korean spot is so fire you need to try it NOW  Lululala  139 Hester st  New York, NY
            Today we're at lululala, a fast casual Korean spot.
            """
        )

        XCTAssertEqual(queries.first, "Lululala 139 Hester st New York, NY")
    }

    func testQueryBuilderPreservesCueAcrossCaptionFieldSeparator() {
        let queries = PlaceQueryBuilder.queries(
            from: "Come with me to check out  Chubby Bowls in Union Square"
        )

        XCTAssertEqual(queries.first, "Chubby Bowls in Union Square")
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
    var expectedEvidence: String?

    init(candidates: [PlaceCandidate], expectedEvidence: String? = nil) {
        self.candidates = candidates
        self.expectedEvidence = expectedEvidence
    }

    func search(evidence: String) async throws -> [PlaceCandidate] {
        if let expectedEvidence, evidence != expectedEvidence {
            throw TestError.unexpectedEvidence
        }
        return candidates
    }
}

private struct FailingMetadataProvider: SocialMetadataProviding {
    func metadata(for url: URL) async throws -> SocialMetadata? {
        throw TestError.metadataUnavailable
    }
}

private enum TestError: Error {
    case metadataUnavailable
    case unexpectedEvidence
}
