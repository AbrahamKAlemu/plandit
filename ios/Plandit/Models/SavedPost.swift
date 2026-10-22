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
    var estimatedCost: Double?
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
        case estimatedCost
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
        estimatedCost: Double? = nil,
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
        self.estimatedCost = estimatedCost
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
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost)
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
        try container.encodeIfPresent(estimatedCost, forKey: .estimatedCost)
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
        let parts = [platform.displayName, creatorHandle, savedAt.relativeDayText]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    /// "Saved today", "Saved yesterday", "Saved 3 days ago", "Saved 2 weeks ago", "Saved 4 months ago".
    /// Shown when picking places so an old save (maybe a pop-up that's over) stands out.
    func savedAgoText(now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: savedAt), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Saved today"
        case 1: return "Saved yesterday"
        case 2..<14: return "Saved \(days) days ago"
        case 14..<60: return "Saved \(days / 7) weeks ago"
        case 60..<365: return "Saved \(days / 30) months ago"
        default: return days < 730 ? "Saved over a year ago" : "Saved \(days / 365) years ago"
        }
    }

    /// Has a place we can pin and add to a plan.
    var isMappable: Bool { place != nil && (status == .ready || status == .needsReview) }

    mutating func apply(_ result: ExtractionResult) {
        creatorHandle = result.creatorHandle ?? creatorHandle
        caption = result.caption ?? caption
        thumbnailURL = result.thumbnailURL ?? thumbnailURL
        candidates = result.candidates
        failureMessage = nil
        status = result.candidates.isEmpty ? .needsEvidence : .needsConfirmation
    }
}
