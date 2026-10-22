import Foundation

struct PlaceCandidate: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var place: Place
    var confidence: CandidateConfidence
    var reason: String
    var estimatedCost: Double?
}

enum CandidateConfidence: String, Hashable, Codable, Sendable {
    case high
    case medium
    case low

    var label: String {
        switch self {
        case .high: "Strong match"
        case .medium: "Possible match"
        case .low: "Check this match"
        }
    }
}
