import Foundation

/// Something the user adds to their budget themselves: "Tickets $25", "Drinks $12", "Snacks $8".
struct CostItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var amount: Double

    init(id: UUID = UUID(), name: String, amount: Double) {
        self.id = id
        self.name = name
        self.amount = max(0, amount)
    }
}

extension [CostItem] {
    var total: Double { reduce(0) { $0 + $1.amount } }
}

/// What a place usually costs per person and where that number comes from, like the
/// "$10–20" Google Maps shows. The number in the plan is always the user's to change.
struct PriceGuide: Equatable {
    enum Source: Equatable {
        /// The saved TikTok or Reel said what it costs.
        case post
        /// No price in the post: what this kind of place usually costs in NYC.
        case typical(PlaceCategory)
    }

    var low: Double
    var high: Double
    /// The number the plan uses when the user hasn't set one.
    var estimate: Double
    var source: Source

    /// "Free", "$6" or "$15–30".
    var rangeText: String {
        if high <= 0 { return "Free" }
        if low == high { return estimate.dollarsText }
        return "\(low.wholeDollarsText)–\(high.wholeDollarsText.dropFirst())"
    }

    /// "Usually $15–30 per person" or "$6 per person".
    var perPersonText: String {
        if high <= 0 { return "Free" }
        return low == high ? "\(rangeText) per person" : "Usually \(rangeText) per person"
    }

    var sourceText: String {
        switch source {
        case .post: "From the saved post"
        case .typical(let category): "Typical for \(category.pricingNoun) in NYC"
        }
    }

    /// The price a post states.
    static func stated(_ amount: Double) -> PriceGuide {
        PriceGuide(low: amount, high: amount, estimate: amount, source: .post)
    }

    static func typical(_ category: PlaceCategory) -> PriceGuide {
        let range = category.typicalPrice
        return PriceGuide(low: range.low, high: range.high, estimate: range.estimate, source: .typical(category))
    }
}

extension PlaceCategory {
    /// Per person in Manhattan, before tax and tip. A starting point only: every stop's cost can be changed.
    var typicalPrice: (low: Double, high: Double, estimate: Double) {
        switch self {
        case .food: (15, 30, 20)
        case .coffee: (5, 10, 7)
        case .activity: (15, 40, 25)
        case .outdoors: (0, 0, 0)
        case .culture: (10, 30, 20)
        case .nightlife: (20, 45, 30)
        case .shopping: (20, 60, 30)
        }
    }

    /// "food", "a coffee spot": reads after "Typical for".
    var pricingNoun: String {
        switch self {
        case .food: "food"
        case .coffee: "coffee"
        case .activity: "activities"
        case .outdoors: "parks"
        case .culture: "museums"
        case .nightlife: "a night out"
        case .shopping: "shopping"
        }
    }
}

extension SavedPost {
    /// Where this place's price comes from, before the user changes anything.
    var postedPrice: PriceGuide? {
        guard let place else { return nil }
        if let estimatedCost { return .stated(estimatedCost) }
        return .typical(place.category)
    }

    /// What the planner budgets for this place: the user's number, the post's, or the typical price.
    var plannedCost: Double? {
        userCost ?? postedPrice?.estimate
    }
}
