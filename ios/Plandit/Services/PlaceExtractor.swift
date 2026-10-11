import Foundation

/// What Plandit learned from a shared post.
struct ExtractionResult {
    var creatorHandle: String?
    var caption: String?
    var thumbnailURL: URL?
    var place: Place?
    var estimatedCost: Double?
    var tags: [String] = []
    var needsReview = false
}

/// Turns a shared TikTok / Reel / link into a place on the map.
protocol PlaceExtracting {
    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult
}

/// Scaffold implementation: real TikTok metadata via public oEmbed, then a stubbed place match.
/// TODO: Replace the stub with the Plandit backend (caption + transcript + on-screen text → place via LLM + a places API).
struct StubPlaceExtractor: PlaceExtracting {
    var oEmbed = OEmbedClient()

    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
        let metadata = try? await oEmbed.metadata(for: url)
        try await Task.sleep(for: .seconds(1.5)) // stand-in for backend latency
        let match = SampleData.extractionPool.randomElement()
        return ExtractionResult(
            creatorHandle: metadata?.authorHandle,
            caption: metadata?.title ?? sharedText,
            thumbnailURL: metadata?.thumbnailURL,
            place: match?.place,
            estimatedCost: match?.cost,
            tags: match?.tags ?? [],
            needsReview: match?.place.hours == nil
        )
    }
}

/// Public post metadata. TikTok's oEmbed endpoint needs no key; Instagram's needs a Meta app token,
/// so fetch Instagram metadata server-side.
struct OEmbedClient {
    struct Metadata {
        var title: String?
        var authorHandle: String?
        var thumbnailURL: URL?
    }

    private struct TikTokResponse: Decodable {
        let title: String?
        let authorUniqueId: String?
        let thumbnailUrl: URL?
    }

    func metadata(for url: URL) async throws -> Metadata? {
        guard SourcePlatform(url: url) == .tiktok,
              var components = URLComponents(string: "https://www.tiktok.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let endpoint = components.url else { return nil }

        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(TikTokResponse.self, from: data)
        return Metadata(
            title: response.title,
            authorHandle: response.authorUniqueId.map { "@\($0)" },
            thumbnailURL: response.thumbnailUrl
        )
    }
}
