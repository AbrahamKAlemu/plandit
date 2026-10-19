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
