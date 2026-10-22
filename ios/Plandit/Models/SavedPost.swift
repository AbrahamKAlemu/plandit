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
        place = result.place
        estimatedCost = result.estimatedCost
        tags = result.tags
        status = result.place == nil ? .failed : (result.needsReview ? .needsReview : .ready)
    }
}
