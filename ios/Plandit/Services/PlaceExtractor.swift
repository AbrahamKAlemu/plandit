import Foundation
import MapKit

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

protocol PlaceSearching: Sendable {
    func search(evidence: String) async throws -> [PlaceCandidate]
}

struct SocialMetadata: Sendable {
    var title: String?
    var authorHandle: String?
    var thumbnailURL: URL?
}

struct FixturePlaceExtractor: PlaceExtracting {
    let metadataProvider: (any SocialMetadataProviding)?
    let placeSearcher: (any PlaceSearching)?

    init(
        metadataProvider: (any SocialMetadataProviding)? = TikTokOEmbedClient(),
        placeSearcher: (any PlaceSearching)? = MapKitPlaceSearcher()
    ) {
        self.metadataProvider = metadataProvider
        self.placeSearcher = placeSearcher
    }

    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
        let metadata = try? await metadataProvider?.metadata(for: url)
        let evidence = [metadata?.title, sharedText]
            .compactMap { $0 }
            .joined(separator: "\n")
        let candidates = try await candidates(matching: evidence)
        return ExtractionResult(
            creatorHandle: metadata?.authorHandle,
            caption: metadata?.title ?? sharedText,
            thumbnailURL: metadata?.thumbnailURL,
            candidates: candidates
        )
    }

    func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
        ExtractionResult(caption: evidence, candidates: try await candidates(matching: evidence))
    }

    private func candidates(matching evidence: String) async throws -> [PlaceCandidate] {
        let fixtures = Self.fixtureCandidates(matching: evidence)
        guard fixtures.isEmpty,
              !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let placeSearcher else {
            return fixtures
        }
        return try await placeSearcher.search(evidence: evidence)
    }

    private static func fixtureCandidates(matching evidence: String) -> [PlaceCandidate] {
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

struct MapKitPlaceSearcher: PlaceSearching {
    func search(evidence: String) async throws -> [PlaceCandidate] {
        var seen = Set<String>()
        var candidates: [PlaceCandidate] = []
        var completedSearch = false
        var lastError: Error?

        for query in PlaceQueryBuilder.queries(from: evidence) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            let response: MKLocalSearch.Response
            do {
                response = try await MKLocalSearch(request: request).start()
                completedSearch = true
            } catch {
                lastError = error
                continue
            }

            for item in response.mapItems {
                guard let candidate = Self.candidate(from: item) else { continue }
                let key = candidate.id
                guard seen.insert(key).inserted else { continue }
                candidates.append(candidate)
                if candidates.count == 3 { return candidates }
            }
        }
        if !completedSearch, let lastError {
            throw lastError
        }
        return candidates
    }

    private static func candidate(from item: MKMapItem) -> PlaceCandidate? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let placemark = item.placemark
        let coordinate = placemark.coordinate
        let address = placemark.title ?? [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let neighborhood = placemark.subLocality ?? placemark.locality ?? "Area unavailable"
        let stableName = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let id = "mapkit:\(stableName):\(coordinate.latitude):\(coordinate.longitude)"
        return PlaceCandidate(
            id: id,
            place: Place(
                name: name,
                category: category(for: item.pointOfInterestCategory),
                neighborhood: neighborhood,
                address: address,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ),
            confidence: .medium,
            reason: "Apple Maps matched the caption or approved text",
            estimatedCost: nil
        )
    }

    private static func category(for pointOfInterest: MKPointOfInterestCategory?) -> PlaceCategory {
        switch pointOfInterest {
        case .cafe:
            return .coffee
        case .restaurant, .bakery, .brewery, .foodMarket, .winery:
            return .food
        case .museum, .library, .theater:
            return .culture
        case .park, .beach, .nationalPark:
            return .outdoors
        case .nightlife:
            return .nightlife
        case .store:
            return .shopping
        default:
            return .activity
        }
    }
}

enum PlaceQueryBuilder {
    static func queries(from evidence: String) -> [String] {
        let cleanedLines = evidence
            .components(separatedBy: .newlines)
            .map(clean)
            .filter { $0.count >= 3 }
        var queries: [String] = []

        for line in cleanedLines {
            if let cueQuery = queryAfterCue(in: line) {
                queries.append(cueQuery)
            }
            queries.append(String(line.prefix(140)))
        }

        var seen = Set<String>()
        return queries.filter {
            let key = $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(key).inserted
        }.prefix(3).map { $0 }
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"https?://\S+|@\w+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"#([A-Za-z0-9_]+)"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func queryAfterCue(in text: String) -> String? {
        guard let range = text.range(
            of: #"\b(?:at|visit|try|called)\s+(.+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let match = String(text[range])
        guard let firstSpace = match.firstIndex(of: " ") else { return nil }
        let query = match[match.index(after: firstSpace)...]
            .split(separator: ".", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return query.flatMap { $0.count >= 3 ? $0 : nil }
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
