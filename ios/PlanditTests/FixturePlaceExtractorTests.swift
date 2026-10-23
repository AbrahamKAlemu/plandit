import XCTest
@testable import Plandit

final class FixturePlaceExtractorTests: XCTestCase {
    @MainActor func testKnownEvidenceReturnsMatchingPlaceFirst() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        let url = URL(string: "https://www.tiktok.com/@creator/video/123")!

        let result = try await extractor.extract(
            from: url,
            sharedText: "You have to try Levain Bakery on the Upper West Side"
        )

        XCTAssertEqual(result.candidates.first?.place.name, "Levain Bakery")
        XCTAssertLessThanOrEqual(result.candidates.count, 3)
    }

    @MainActor func testUnknownEvidenceNeedsMoreDetails() async throws {
        let extractor = FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        let url = URL(string: "https://www.instagram.com/reel/ABC/")!

        let result = try await extractor.extract(from: url, sharedText: nil)

        XCTAssertTrue(result.candidates.isEmpty)
    }

    @MainActor func testTikTokMetadataFallsBackToPlaceSearch() async throws {
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

    @MainActor func testSearchOnlyEvidenceIsNotReturnedAsPersistableCaption() async throws {
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

    @MainActor func testMetadataProviderFallsBackAfterPrimaryFailure() async throws {
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

    @MainActor func testDailyLimitSurvivesAnEmptyTikTokFallback() async {
        let provider = FallbackSocialMetadataProvider(
            primary: QuotaMetadataProvider(),
            fallback: StubMetadataProvider(
                metadata: SocialMetadata(
                    title: nil,
                    authorHandle: nil,
                    thumbnailURL: nil
                )
            )
        )

        do {
            _ = try await provider.metadata(
                for: URL(string: "https://www.tiktok.com/@creator/video/123")!
            )
            XCTFail("Expected the daily limit to be preserved")
        } catch {
            XCTAssertEqual(error as? DevelopmentSocialEvidenceError, .dailyLimit)
        }
    }

    @MainActor func testCaptionFallbackStillWorksDuringDailyLimit() async throws {
        let provider = FallbackSocialMetadataProvider(
            primary: QuotaMetadataProvider(),
            fallback: StubMetadataProvider(
                metadata: SocialMetadata(
                    title: "Levain Bakery on the Upper West Side",
                    authorHandle: "@creator",
                    thumbnailURL: nil
                )
            )
        )

        let metadata = try await provider.metadata(
            for: URL(string: "https://www.tiktok.com/@creator/video/123")!
        )

        XCTAssertEqual(metadata?.title, "Levain Bakery on the Upper West Side")
    }

    @MainActor func testSharedPlaceTextStillResolvesDuringDailyLimit() async throws {
        let extractor = FixturePlaceExtractor(
            metadataProvider: FallbackSocialMetadataProvider(
                primary: QuotaMetadataProvider(),
                fallback: StubMetadataProvider(
                    metadata: SocialMetadata(
                        title: nil,
                        authorHandle: nil,
                        thumbnailURL: nil
                    )
                )
            ),
            placeSearcher: nil
        )

        let result = try await extractor.extract(
            from: URL(string: "https://www.tiktok.com/@creator/video/123")!,
            sharedText: "Try Levain Bakery on the Upper West Side https://www.tiktok.com/@creator/video/123"
        )

        XCTAssertEqual(result.candidates.first?.place.name, "Levain Bakery")
    }

    @MainActor func testUrlOnlyShareStillReportsDailyLimit() async {
        let extractor = FixturePlaceExtractor(
            metadataProvider: QuotaMetadataProvider(),
            placeSearcher: nil
        )

        do {
            _ = try await extractor.extract(
                from: URL(string: "https://www.tiktok.com/@creator/video/123")!,
                sharedText: "https://www.tiktok.com/@creator/video/123"
            )
            XCTFail("Expected the daily limit")
        } catch {
            XCTAssertEqual(error as? DevelopmentSocialEvidenceError, .dailyLimit)
        }
    }

    @MainActor func testDevelopmentEvidenceRequestBypassesURLCache() throws {
        let request = try XCTUnwrap(DevelopmentSocialEvidenceClient.request(
            for: URL(string: "https://www.tiktok.com/t/ZTfDj7vmC/")!
        ))

        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }

    @MainActor func testProductionEvidenceRequestUsesConfiguredEndpointAndBearerToken() throws {
        let endpoint = URL(string: "https://api.plandit.example/v1/social-evidence")!
        let request = try XCTUnwrap(DevelopmentSocialEvidenceClient.request(
            for: URL(string: "https://www.tiktok.com/t/ZTfDj7vmC/")!,
            endpoint: endpoint,
            accessToken: "test-access-token"
        ))

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-access-token"
        )
    }

    @MainActor func testDevelopmentEvidenceClientRecognizesDailyLimit() {
        let data = Data(
            """
            {"error":{"code":"provider_quota_exceeded"}}
            """.utf8
        )

        XCTAssertEqual(
            DevelopmentSocialEvidenceClient.providerError(
                statusCode: 429,
                data: data
            ),
            .dailyLimit
        )
    }

    @MainActor func testQueryBuilderPrioritizesPlaceAfterCue() {
        let queries = PlaceQueryBuilder.queries(
            from: "Best slice in NYC at Joe's Pizza #foodtok"
        )

        XCTAssertEqual(queries.first, "Joe's Pizza foodtok")
    }

    @MainActor func testQueryBuilderExtractsPlaceAfterCheckOut() {
        let queries = PlaceQueryBuilder.queries(
            from: "Come with me to check out Chubby Bowls in Union Square! Great food."
        )

        XCTAssertEqual(queries.first, "Chubby Bowls in Union Square")
    }

    @MainActor func testQueryBuilderPrioritizesCompleteCaptionAddress() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            NYC is too expensive is back! $7 chicken bowl at this Korean spot is so fire you need to try it NOW  Lululala  139 Hester st  New York, NY
            Today we're at lululala, a fast casual Korean spot.
            """
        )

        XCTAssertEqual(queries.first, "139 Hester st New York, NY")
    }

    @MainActor func testQueryBuilderPreservesCueAcrossCaptionFieldSeparator() {
        let queries = PlaceQueryBuilder.queries(
            from: "Come with me to check out  Chubby Bowls in Union Square"
        )

        XCTAssertEqual(queries.first, "Chubby Bowls in Union Square")
    }

    @MainActor func testQueryBuilderAssociatesBusinessMentionWithDistantAddress() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            Must Try Dominican Street Food in Brooklyn!  @Antojitos BK is a Dominican restaurant in Brooklyn serving fire dishes.  SR Rating: A.  📍224 4th Avenue Brooklyn, NY 11215
            I stumbled on this Dominican street food restaurant
            called antojitos, and I just had to put y'all on.
            """
        )

        XCTAssertEqual(
            queries.first,
            "224 4th Avenue Brooklyn, NY 11215"
        )
    }

    @MainActor func testQueryBuilderDoesNotTreatCreatorHandleAsVenue() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            @Antojitos BK is a Dominican restaurant in Brooklyn.  @foodwithsam is the creator reviewing this restaurant.  224 4th Avenue Brooklyn, NY 11215
            """
        )

        XCTAssertEqual(
            queries.first,
            "224 4th Avenue Brooklyn, NY 11215"
        )
    }

    @MainActor func testQueryBuilderPairsEachVenueWithNearestAddress() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            @Cafe One is a neighborhood cafe.  1 First St New York, NY 10001
            @Cafe Two is a neighborhood cafe.  2 Second St Brooklyn, NY 11201
            """
        )

        XCTAssertEqual(queries.first, "1 First St New York, NY 10001")
        XCTAssertEqual(queries.dropFirst().first, "2 Second St Brooklyn, NY 11201")
        XCTAssertEqual(
            queries.dropFirst(2).first,
            "Cafe One 1 First St New York, NY 10001"
        )
    }

    @MainActor func testQueryBuilderPreservesRepeatedVenuePositionForPairing() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            @Cafe One is a neighborhood cafe. @Cafe Two is a neighborhood cafe.
            This next place is called Cafe One. 1 First St New York, NY 10001
            """
        )

        XCTAssertEqual(queries.first, "1 First St New York, NY 10001")
    }

    @MainActor func testQueryBuilderUsesSquareAddressIndependently() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            Brooklyn, NY — we had to see what the hype was about. We stopped by Fat Fowl, a Caribbean spot inside DeKalb Market Hall.
            📍 Fat Fowl — DeKalb Market Hall, Brooklyn 445 Albee square, Brooklyn Ny 11201
            """
        )

        XCTAssertEqual(
            queries.first,
            "445 Albee square, Brooklyn Ny 11201"
        )
        XCTAssertEqual(
            queries.dropFirst().first,
            "Fat Fowl 445 Albee square, Brooklyn Ny 11201"
        )
    }

    @MainActor func testQueryBuilderSearchesCompleteAddressWithoutPlaceName() {
        let queries = PlaceQueryBuilder.queries(
            from: "The location is 445 Albee Square Brooklyn, NY 11201."
        )

        XCTAssertEqual(queries.first, "445 Albee Square Brooklyn, NY 11201")
    }

    @MainActor func testQueryBuilderRecognizesPinnedPlaceAndExactAddress() {
        let queries = PlaceQueryBuilder.queries(
            from: """
            Original deal — $68 Sunday through Thursday. Kings of Kobe 📍650 W 42nd St, New York, NY 10036
            """
        )

        XCTAssertEqual(
            queries.first,
            "650 W 42nd St, New York, NY 10036"
        )
        XCTAssertEqual(
            queries.dropFirst().first,
            "Kings of Kobe 650 W 42nd St, New York, NY 10036"
        )
    }

    @MainActor func testAddressCandidateMustMatchExtractedHouseNumber() {
        let number = PlaceQueryBuilder.streetNumber(
            from: "Kings of Kobe 650 W 42nd St, New York, NY 10036"
        )

        XCTAssertEqual(number, "650")
        XCTAssertTrue(PlaceQueryBuilder.address(
            "650 W 42nd St, New York, NY 10036",
            matchesStreetNumber: "650"
        ))
        XCTAssertFalse(PlaceQueryBuilder.address(
            "600 W 42nd St, New York, NY 10036",
            matchesStreetNumber: "650"
        ))
        XCTAssertFalse(PlaceQueryBuilder.address(
            "600 W 42nd St, Unit 650, New York, NY 10036",
            matchesStreetNumber: "650"
        ))
    }

    @MainActor func testStreetNumberIgnoresPricesAndSupportsRanges() {
        XCTAssertNil(PlaceQueryBuilder.streetNumber(
            from: "Only $68 dinner on West 42nd St"
        ))
        XCTAssertNil(PlaceQueryBuilder.streetNumber(
            from: "$25 prix fixe near Grove Street"
        ))
        XCTAssertEqual(
            PlaceQueryBuilder.streetNumber(from: "650-652 W 42nd St"),
            "650-652"
        )
        XCTAssertTrue(PlaceQueryBuilder.address(
            "650 W 42nd St, New York, NY",
            matchesStreetNumber: "650-652"
        ))
        XCTAssertTrue(PlaceQueryBuilder.address(
            "650-652 W 42nd St, New York, NY",
            matchesStreetNumber: "652"
        ))
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

private struct QuotaMetadataProvider: SocialMetadataProviding {
    func metadata(for url: URL) async throws -> SocialMetadata? {
        throw DevelopmentSocialEvidenceError.dailyLimit
    }
}

private enum TestError: Error {
    case metadataUnavailable
    case unexpectedEvidence
}
