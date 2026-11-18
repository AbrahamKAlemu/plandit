import Foundation

struct UserProfile: Codable, Equatable {
    var name: String
    var school: String
    var homeBase: String
    var defaultBudget: Double
    var travelModes: String

    var initial: String { String(name.trimmingCharacters(in: .whitespaces).prefix(1)) }

    /// How the planner is allowed to move you between stops.
    static let travelOptions = ["Walk only", "Walk + subway", "Walk + subway + bus"]
}

struct UserStats: Codable, Equatable {
    var plansCompleted: Int
    var neighborhoodsExplored: Int
    var placesSaved: Int

    static let empty = UserStats(plansCompleted: 0, neighborhoodsExplored: 0, placesSaved: 0)

    /// Real numbers from what the person actually did.
    /// - plans completed: every past plan
    /// - neighborhoods explored: distinct non-empty neighborhoods among places in completed plans
    /// - places saved: every saved post
    static func compute(pastPlans: [PastPlan], visited: [Place], placesSaved: Int) -> UserStats {
        let neighborhoods = Set(visited.map { $0.neighborhood.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return UserStats(plansCompleted: pastPlans.count, neighborhoodsExplored: neighborhoods.count, placesSaved: placesSaved)
    }
}

struct PastPlan: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    var stopCount: Int
    var cost: Double
    /// Recorded at rollover since accounts began; absent in older files.
    var budget: Double?
    var walkingMiles: Double?
    /// Subway and bus fares included in `cost`. Recorded at rollover since 1.0.1; absent in older files.
    var fares: Double?
}
