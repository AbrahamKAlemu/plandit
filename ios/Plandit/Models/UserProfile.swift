import Foundation

struct UserProfile {
    var name: String
    var school: String
    var homeBase: String
    var defaultBudget: Double
    var travelModes: String

    var initial: String { String(name.prefix(1)) }
}

struct UserStats {
    var plansCompleted: Int
    var neighborhoodsVisited: Int
    var milesWalked: Double
    var averageSpend: Double
    var plansUnderBudget: Int
    var streakWeeks: Int
}

struct PastPlan: Identifiable {
    var id = UUID()
    var title: String
    var date: Date
    var stopCount: Int
    var cost: Double
}
