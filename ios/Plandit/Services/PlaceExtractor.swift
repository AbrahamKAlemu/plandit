import Foundation

struct ExtractionResult: Sendable {
    var creatorHandle: String?
    var caption: String?
    var thumbnailURL: URL?
    var candidates: [PlaceCandidate]
}

protocol PlaceExtracting: Sendable {
    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult
    func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult
}

protocol SocialMetadataProviding: Sendable {
    func metadata(for url: URL) async throws -> SocialMetadata?
}

struct SocialMetadata: Sendable {
    var title: String?
    var authorHandle: String?
    var thumbnailURL: URL?
}

struct FixturePlaceExtractor: PlaceExtracting {
    let metadataProvider: (any SocialMetadataProviding)?

    init(metadataProvider: (any SocialMetadataProviding)? = TikTokOEmbedClient()) {
        self.metadataProvider = metadataProvider
    }

    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
        let metadata = try? await metadataProvider?.metadata(for: url)
        let evidence = [metadata?.title, sharedText]
            .compactMap { $0 }
            .joined(separator: "\n")
        return ExtractionResult(
            creatorHandle: metadata?.authorHandle,
            caption: metadata?.title ?? sharedText,
            thumbnailURL: metadata?.thumbnailURL,
            candidates: Self.candidates(matching: evidence)
        )
    }

    func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
        ExtractionResult(caption: evidence, candidates: Self.candidates(matching: evidence))
    }

    private static func candidates(matching evidence: String) -> [PlaceCandidate] {
        let normalized = evidence.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let fixtures: [(aliases: [String], candidate: PlaceCandidate)] = [
            (
                ["levain", "cookie worth the line"],
                PlaceCandidate(
                    id: "fixture:levain",
                    place: SampleData.levain,
                    confidence: .high,
                    reason: "Place name matched the shared text",
                    estimatedCost: 6
                )
            ),
            (
                ["los tacos", "adobada taco", "chelsea market"],
                PlaceCandidate(
                    id: "fixture:los-tacos",
                    place: SampleData.losTacos,
                    confidence: .high,
                    reason: "Restaurant and neighborhood matched",
                    estimatedCost: 15
                )
            ),
            (
                ["hungarian pastry", "study spot near campus"],
                PlaceCandidate(
                    id: "fixture:hungarian-pastry",
                    place: SampleData.hungarianPastry,
                    confidence: .high,
                    reason: "Place description matched the shared text",
                    estimatedCost: 9
                )
            ),
            (
                ["little island", "pier 55"],
                PlaceCandidate(
                    id: "fixture:little-island",
                    place: SampleData.littleIsland,
                    confidence: .high,
                    reason: "Place name matched the shared text",
                    estimatedCost: 0
                )
            ),
            (
                ["met cloisters", "cloisters", "medieval castle"],
                PlaceCandidate(
                    id: "fixture:cloisters",
                    place: SampleData.cloisters,
                    confidence: .medium,
                    reason: "Description and area matched",
                    estimatedCost: 5
                )
            ),
        ]

        return fixtures
            .filter { fixture in fixture.aliases.contains { normalized.localizedCaseInsensitiveContains($0) } }
            .map(\.candidate)
            .prefix(3)
            .map { $0 }
    }
}

struct TikTokOEmbedClient: SocialMetadataProviding {
    private struct Response: Decodable {
        let title: String?
        let authorUniqueId: String?
        let thumbnailUrl: URL?
    }

    func metadata(for url: URL) async throws -> SocialMetadata? {
        let supported = try SupportedSocialURL(url)
        guard supported.platform == .tiktok,
              var components = URLComponents(string: "https://www.tiktok.com/oembed") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "url", value: supported.canonicalURL.absoluteString)]
        guard let endpoint = components.url else { return nil }

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Response.self, from: data)
        return SocialMetadata(
            title: payload.title,
            authorHandle: payload.authorUniqueId.map { "@\($0)" },
            thumbnailURL: payload.thumbnailUrl
        )
    }
}
