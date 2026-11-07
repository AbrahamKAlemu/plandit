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
    var neighborhoodsVisited: Int
    var milesWalked: Double
    var averageSpend: Double
    var plansUnderBudget: Int
    var streakWeeks: Int

    static let empty = UserStats(plansCompleted: 0, neighborhoodsVisited: 0, milesWalked: 0, averageSpend: 0, plansUnderBudget: 0, streakWeeks: 0)

    /// Real numbers from what the person actually did.
    /// - plans completed: every past plan
    /// - neighborhoods: distinct non-empty neighborhoods among visited places
    /// - miles walked: sum of past plans' walking miles (older plans without the field count 0)
    /// - average spend: mean past-plan cost, 0 when there are none
    /// - under budget: past plans that recorded a budget and cost at most that much
    /// - streak: consecutive weeks with at least one past plan, ending this week or last week
    static func compute(pastPlans: [PastPlan], visited: [Place], now: Date = .now, calendar: Calendar = .current) -> UserStats {
        let neighborhoods = Set(visited.map { $0.neighborhood.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let costs = pastPlans.map(\.cost)
        let average = costs.isEmpty ? 0 : costs.reduce(0, +) / Double(costs.count)
        let underBudget = pastPlans.filter { plan in plan.budget.map { plan.cost <= $0 } ?? false }.count
        return UserStats(
            plansCompleted: pastPlans.count,
            neighborhoodsVisited: neighborhoods.count,
            milesWalked: pastPlans.reduce(0) { $0 + ($1.walkingMiles ?? 0) },
            averageSpend: average,
            plansUnderBudget: underBudget,
            streakWeeks: streak(pastPlans: pastPlans, now: now, calendar: calendar)
        )
    }

    private static func streak(pastPlans: [PastPlan], now: Date, calendar: Calendar) -> Int {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        let weeks = Set(pastPlans.compactMap { calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start })
        guard !weeks.isEmpty else { return 0 }
        var cursor = thisWeek
        if !weeks.contains(cursor) {
            guard let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor), weeks.contains(lastWeek) else { return 0 }
            cursor = lastWeek
        }
        var count = 0
        while weeks.contains(cursor), let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) {
            count += 1
            cursor = previous
        }
        return count
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
}
