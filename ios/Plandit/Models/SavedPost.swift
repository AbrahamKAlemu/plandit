import Foundation

/// A TikTok, Reel or link shared into Plandit, plus whatever we've extracted from it.
struct SavedPost: Identifiable, Hashable, Codable {
    var id = UUID()
    var url: URL
    var canonicalURL: URL
    var platform: SourcePlatform
    var creatorHandle: String?
    var caption: String?
    var thumbnailURL: URL?
    var savedAt: Date
    var status: ExtractionStatus
    var place: Place?
    var placeProviderID: String?
    var estimatedCost: Double?
    /// The user's own price for this place. Wins over `estimatedCost` and the typical price.
    var userCost: Double?
    var tags: [String] = []
    var candidates: [PlaceCandidate] = []
    var failureMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case canonicalURL
        case platform
        case creatorHandle
        case caption
        case thumbnailURL
        case savedAt
        case status
        case place
        case placeProviderID
        case estimatedCost
        case userCost
        case tags
        case candidates
        case failureMessage
    }

    init(
        id: UUID = UUID(),
        url: URL,
        canonicalURL: URL? = nil,
        platform: SourcePlatform,
        creatorHandle: String? = nil,
        caption: String? = nil,
        thumbnailURL: URL? = nil,
        savedAt: Date,
        status: ExtractionStatus,
        place: Place? = nil,
        placeProviderID: String? = nil,
        estimatedCost: Double? = nil,
        userCost: Double? = nil,
        tags: [String] = [],
        candidates: [PlaceCandidate] = [],
        failureMessage: String? = nil
    ) {
        self.id = id
        self.url = url
        self.canonicalURL = canonicalURL ?? url
        self.platform = platform
        self.creatorHandle = creatorHandle
        self.caption = caption
        self.thumbnailURL = thumbnailURL
        self.savedAt = savedAt
        self.status = status
        self.place = place
        self.placeProviderID = placeProviderID
        self.estimatedCost = estimatedCost
        self.userCost = userCost
        self.tags = tags
        self.candidates = candidates
        self.failureMessage = failureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try container.decode(URL.self, forKey: .url)
        canonicalURL = try container.decodeIfPresent(URL.self, forKey: .canonicalURL) ?? url
        platform = try container.decode(SourcePlatform.self, forKey: .platform)
        creatorHandle = try container.decodeIfPresent(String.self, forKey: .creatorHandle)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
        status = try container.decode(ExtractionStatus.self, forKey: .status)
        place = try container.decodeIfPresent(Place.self, forKey: .place)
        placeProviderID = try container.decodeIfPresent(String.self, forKey: .placeProviderID)
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost)
        userCost = try container.decodeIfPresent(Double.self, forKey: .userCost)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        candidates = try container.decodeIfPresent([PlaceCandidate].self, forKey: .candidates) ?? []
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(canonicalURL, forKey: .canonicalURL)
        try container.encode(platform, forKey: .platform)
        try container.encodeIfPresent(creatorHandle, forKey: .creatorHandle)
        try container.encodeIfPresent(caption, forKey: .caption)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(place, forKey: .place)
        try container.encodeIfPresent(placeProviderID, forKey: .placeProviderID)
        try container.encodeIfPresent(estimatedCost, forKey: .estimatedCost)
        try container.encodeIfPresent(userCost, forKey: .userCost)
        try container.encode(tags, forKey: .tags)
        try container.encode(candidates, forKey: .candidates)
        try container.encodeIfPresent(failureMessage, forKey: .failureMessage)
    }
}

enum ExtractionStatus: String, Codable {
    /// Waiting on metadata + place matching.
    case processing
    /// More caption, screenshot, video, or typed evidence is needed.
    case needsEvidence
    /// Candidate places are ready for explicit confirmation.
    case needsConfirmation
    /// Place found and confirmed.
    case ready
    /// Place found, but something (hours, price, exact location) needs a human check.
    case needsReview
    /// No place found in the post.
    case failed
}

extension SavedPost {
    var title: String {
        if let place { return place.name }
        return switch status {
        case .failed: "No place found"
        case .needsEvidence: "More details needed"
        case .needsConfirmation: candidates.first?.place.name ?? "Confirm the place"
        case .processing: "Finding the place…"
        case .ready, .needsReview: "Saved place"
        }
    }

    var sourceLine: String {
        let parts = [platform.displayName, creatorHandle, savedAgoText()]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// When it was saved: "Today", "Yesterday", "3 days ago" up to 6 days, then "Nov 6" ("Nov 6, 2025"
    /// in an earlier year). Every saved date in the app reads this way (W-10).
    func savedAgoText(now: Date = .now, calendar: Calendar = .current) -> String {
        let days = savedDaysAgo(now: now, calendar: calendar)
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default:
            var style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            if calendar.component(.year, from: savedAt) != calendar.component(.year, from: now) {
                style = style.year()
            }
            return savedAt.formatted(style)
        }
    }

    /// The same date with "Saved" in front, for rows where a bare date would be unclear:
    /// "Saved today", "Saved yesterday", "Saved 3 days ago", "Saved Nov 6".
    func savedWhenText(now: Date = .now, calendar: Calendar = .current) -> String {
        switch savedDaysAgo(now: now, calendar: calendar) {
        case ..<1: "Saved today"
        case 1: "Saved yesterday"
        default: "Saved \(savedAgoText(now: now, calendar: calendar))"
        }
    }

    private func savedDaysAgo(now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: savedAt), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// Has a place we can pin and add to a plan.
    var isMappable: Bool { place != nil && (status == .ready || status == .needsReview) }

    mutating func apply(_ result: ExtractionResult) {
        canonicalURL = result.canonicalURL ?? canonicalURL
        creatorHandle = result.creatorHandle ?? creatorHandle
        caption = result.caption ?? caption
        thumbnailURL = result.thumbnailURL ?? thumbnailURL
        failureMessage = nil
        if let candidateID = result.autoConfirmedCandidateID,
           let candidate = result.candidates.first(where: { $0.id == candidateID }) {
            place = candidate.place
            placeProviderID = candidate.id
            estimatedCost = candidate.estimatedCost
            candidates = []
            status = .ready
        } else {
            candidates = result.candidates
            status = result.candidates.isEmpty ? .needsEvidence : .needsConfirmation
        }
    }
}
