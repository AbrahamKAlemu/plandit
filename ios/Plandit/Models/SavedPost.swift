import Foundation

/// A TikTok, Reel or link shared into Plandit, plus whatever we've extracted from it.
struct SavedPost: Identifiable, Hashable, Codable {
    var id = UUID()
    var url: URL
    var platform: SourcePlatform
    var creatorHandle: String?
    var caption: String?
    var thumbnailURL: URL?
    var savedAt: Date
    var status: ExtractionStatus
    var place: Place?
    var estimatedCost: Double?
    var tags: [String] = []
}

enum ExtractionStatus: String, Codable {
    /// Waiting on metadata + place matching.
    case processing
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
        return status == .failed ? "No place found" : "Finding the place…"
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
        place = result.place
        estimatedCost = result.estimatedCost
        tags = result.tags
        status = result.place == nil ? .failed : (result.needsReview ? .needsReview : .ready)
    }
}
