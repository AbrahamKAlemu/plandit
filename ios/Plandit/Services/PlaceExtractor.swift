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
    var searchEvidence: String? = nil

    var hasPlaceEvidence: Bool {
        [searchEvidence, title].contains {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

struct FixturePlaceExtractor: PlaceExtracting {
    let metadataProvider: (any SocialMetadataProviding)?
    let placeSearcher: (any PlaceSearching)?

    init(
        metadataProvider: (any SocialMetadataProviding)? = Self.defaultMetadataProvider,
        placeSearcher: (any PlaceSearching)? = MapKitPlaceSearcher()
    ) {
        self.metadataProvider = metadataProvider
        self.placeSearcher = placeSearcher
    }

    private static var defaultMetadataProvider: any SocialMetadataProviding {
#if DEBUG && targetEnvironment(simulator)
        FallbackSocialMetadataProvider(
            primary: DevelopmentSocialEvidenceClient(),
            fallback: TikTokOEmbedClient()
        )
#else
        TikTokOEmbedClient()
#endif
    }

    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
        let metadata: SocialMetadata?
        do {
            metadata = try await metadataProvider?.metadata(for: url)
        } catch let error as DevelopmentSocialEvidenceError {
            guard Self.hasMeaningfulSharedText(sharedText) else { throw error }
            metadata = nil
        } catch {
            metadata = nil
        }
        let evidence = [metadata?.searchEvidence, metadata?.title, sharedText]
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

    private static func hasMeaningfulSharedText(_ value: String?) -> Bool {
        let withoutURLs = value?.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        return withoutURLs?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
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
            let requestedStreetNumber = PlaceQueryBuilder.streetNumber(from: query)
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
                if let requestedStreetNumber,
                   !PlaceQueryBuilder.address(
                       candidate.place.address,
                       matchesStreetNumber: requestedStreetNumber
                   ) {
                    continue
                }
                let key = candidate.id
                guard seen.insert(key).inserted else { continue }
                candidates.append(candidate)
                break
            }
            if candidates.count == 3 { return candidates }
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
    private struct PositionedPlaceName {
        let name: String
        let offset: Int
    }

    static func queries(from evidence: String) -> [String] {
        let segmentedEvidence = evidence.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: "\n",
            options: .regularExpression
        )
        let cleanedLines = segmentedEvidence
            .components(separatedBy: .newlines)
            .map(clean)
            .filter { $0.count >= 3 }
        let cueLines = evidence
            .components(separatedBy: .newlines)
            .map(clean)
            .filter { $0.count >= 3 }
        var queries = positionedAddressQueries(from: evidence)
        queries.append(contentsOf: adjacentAddressQueries(from: cleanedLines))

        for line in cueLines {
            if let cueQuery = queryAfterCue(in: line) {
                queries.append(cueQuery)
            }
        }
        for line in cleanedLines {
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

    private static func positionedAddressQueries(from evidence: String) -> [String] {
        let addressPattern = #"\b\d{1,6}\s+[\p{L}0-9.'-]+(?:\s+[\p{L}0-9.'-]+){0,3}\s+(?:st(?:reet)?|ave(?:nue)?|rd|road|blvd|boulevard|dr(?:ive)?|ln|lane|way|pl(?:ace)?|pkwy|parkway|sq(?:uare)?),?(?:\s+[\p{L}.'-]+){0,3},?\s+[A-Z]{2}(?:\s+\d{5})?\b"#
        guard let addressExpression = try? NSRegularExpression(
            pattern: addressPattern,
            options: .caseInsensitive
        ) else {
            return []
        }
        let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
        let placeNames = positionedPlaceNames(from: evidence)
        var addresses: [String] = []
        var combinedQueries: [String] = []

        for match in addressExpression.matches(in: evidence, range: range) {
            let precedingPlaceName = placeNames
                .filter { $0.offset <= match.range.location }
                .max { $0.offset < $1.offset }
            guard let addressRange = Range(match.range, in: evidence) else {
                continue
            }
            let address = clean(String(evidence[addressRange]))
            addresses.append(address)
            if let placeName = precedingPlaceName ?? placeNames.min(by: {
                $0.offset < $1.offset
            }) {
                combinedQueries.append("\(placeName.name) \(address)")
            }
        }
        return addresses + combinedQueries
    }

    private static func adjacentAddressQueries(from lines: [String]) -> [String] {
        let pattern = #"\b\d{1,6}\s+[\p{L}0-9.'-]+(?:\s+[\p{L}0-9.'-]+){0,3}\s+(?:st(?:reet)?|ave(?:nue)?|rd|road|blvd|boulevard|dr(?:ive)?|ln|lane|way|pl(?:ace)?|pkwy|parkway|sq(?:uare)?)\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else {
            return []
        }

        return lines.indices.flatMap { index -> [String] in
            let line = lines[index]
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let addressRange = Range(match.range, in: line) else {
                return []
            }
            var addressParts = [String(line[addressRange.lowerBound...])]
            if !containsState(in: line), index < lines.index(before: lines.endIndex) {
                addressParts.append(lines[lines.index(after: index)])
            }
            let address = addressParts.joined(separator: " ")
            if index > lines.startIndex {
                return ["\(lines[lines.index(before: index)]) \(address)"]
            }
            return [address]
        }
    }

    private static func positionedPlaceNames(from evidence: String) -> [PositionedPlaceName] {
        let patterns = [
            #"@([^@\n.!?]{2,60}?)\s+is\s+(?:an?|the)\s+[^.\n!?]{0,80}?\b(?:restaurant|cafe|bakery|bar|shop|spot|market|store|venue)\b"#,
            #"\bcalled\s+([^,\n.!?]{2,60})"#,
            #"\bstopped\s+by\s+([^,\n.!?]{2,60})"#,
            #"(?:^|[.!?]\s+)([^.!?\n]{2,60}?)\s*📍(?=\s*\d)"#,
        ]
        var names: [PositionedPlaceName] = []

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: .caseInsensitive
            ) else {
                continue
            }
            let range = NSRange(evidence.startIndex..<evidence.endIndex, in: evidence)
            for match in expression.matches(in: evidence, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: evidence) else {
                    continue
                }
                let matchedText = Range(match.range, in: evidence)
                    .map { String(evidence[$0]) } ?? ""
                if matchedText.hasPrefix("@"),
                   matchedText.range(
                       of: #"\b(?:creator|reviewer|influencer|blogger|account|page|person|user|showing|reviewing|visiting|trying)\b"#,
                       options: [.regularExpression, .caseInsensitive]
                   ) != nil {
                    continue
                }
                let name = clean(String(evidence[captureRange]))
                if name.count >= 2 {
                    names.append(PositionedPlaceName(
                        name: name,
                        offset: match.range.location
                    ))
                }
            }
        }

        return names
    }

    private static func containsState(in text: String) -> Bool {
        text.range(
            of: #"(?:,\s*[A-Z]{2}\b|\b[A-Z]{2}\s+\d{5}\b)"#,
            options: .regularExpression
        ) != nil
    }

    static func streetNumber(from query: String) -> String? {
        let pattern = #"(?<![$\d-])\b(\d{1,6}(?:-\d{1,6})?)\s+(?:[\p{L}0-9.'-]+\s+){1,4}(?:st(?:reet)?|ave(?:nue)?|rd|road|blvd|boulevard|dr(?:ive)?|ln|lane|way|pl(?:ace)?|pkwy|parkway|sq(?:uare)?)\b"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else {
            return nil
        }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let match = expression.firstMatch(in: query, range: range),
              let numberRange = Range(match.range(at: 1), in: query) else {
            return nil
        }
        return String(query[numberRange])
    }

    static func address(_ address: String, matchesStreetNumber number: String) -> Bool {
        guard let candidateNumber = streetNumber(from: address),
              let requestedRange = numberRange(number),
              let candidateRange = numberRange(candidateNumber) else {
            return false
        }
        return requestedRange.overlaps(candidateRange)
    }

    private static func numberRange(_ value: String) -> ClosedRange<Int>? {
        let parts = value.split(separator: "-", maxSplits: 1)
        guard let lower = Int(parts[0]),
              let upper = Int(parts.last ?? parts[0]) else {
            return nil
        }
        return min(lower, upper)...max(lower, upper)
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
        let pattern = #"\b(?:check\s+out|stopped\s+by|at|visit|try|called)\s+(.+)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let query = text[captureRange]
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return query.flatMap { $0.count >= 3 ? $0 : nil }
    }
}

struct FallbackSocialMetadataProvider: SocialMetadataProviding {
    let primary: any SocialMetadataProviding
    let fallback: any SocialMetadataProviding

    func metadata(for url: URL) async throws -> SocialMetadata? {
        do {
            if let metadata = try await primary.metadata(for: url) {
                return metadata
            }
        } catch let primaryError as DevelopmentSocialEvidenceError {
            if let metadata = try? await fallback.metadata(for: url),
               metadata.hasPlaceEvidence {
                return metadata
            }
            throw primaryError
        } catch {
            return try await fallback.metadata(for: url)
        }
        return try await fallback.metadata(for: url)
    }
}

enum DevelopmentSocialEvidenceError: LocalizedError, Equatable {
    case dailyLimit

    var errorDescription: String? {
        switch self {
        case .dailyLimit:
            "Automatic TikTok imports are paused for today. Add the place name or address below, or use the saved video instead."
        }
    }
}

struct DevelopmentSocialEvidenceClient: SocialMetadataProviding {
    private struct Response: Decodable {
        let canonicalUrl: URL
        let combinedText: String
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let code: String
        }

        let error: Detail
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(for url: URL) async throws -> SocialMetadata? {
        guard let request = try Self.request(for: url) else {
            return nil
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if let providerError = Self.providerError(
            statusCode: http.statusCode,
            data: data
        ) {
            throw providerError
        }
        guard 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        let creator = payload.canonicalUrl.pathComponents
            .first(where: { $0.hasPrefix("@") })
        return SocialMetadata(
            title: nil,
            authorHandle: creator,
            thumbnailURL: nil,
            searchEvidence: payload.combinedText
        )
    }

    static func providerError(
        statusCode: Int,
        data: Data
    ) -> DevelopmentSocialEvidenceError? {
        guard statusCode == 429,
              let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data),
              payload.error.code == "provider_quota_exceeded" else {
            return nil
        }
        return .dailyLimit
    }

    static func request(for url: URL) throws -> URLRequest? {
        let supported = try SupportedSocialURL(url)
        guard supported.platform == .tiktok,
              let endpoint = URL(string: "http://127.0.0.1:8000/v1/social-evidence") else {
            return nil
        }
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "sourceUrl": supported.canonicalURL.absoluteString
        ])
        return request
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
