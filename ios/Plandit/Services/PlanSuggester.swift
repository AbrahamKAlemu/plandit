import Foundation

/// A ready-made plan for the empty Today, built only from the student's own saves.
struct PlanSuggestion: Identifiable, Equatable {
    /// The post ids joined in plan order: the same plan keeps its id across recomputes.
    var id: String
    /// The saved posts, in plan order.
    var postIDs: [UUID]
    var outcome: DayPlanner.Outcome
    /// Where the stops are: "Chelsea" or "Chelsea and Flatiron".
    var title: String

    static func == (lhs: PlanSuggestion, rhs: PlanSuggestion) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.postIDs == rhs.postIDs && lhs.outcome.isSamePlan(as: rhs.outcome)
    }
}

extension DayPlanner.Outcome {
    /// The same places in the same order, at the same times, for the same money. Stop and leg ids
    /// aside: every planning run makes new ones.
    func isSamePlan(as other: DayPlanner.Outcome) -> Bool {
        stops.map(\.sourcePostID) == other.stops.map(\.sourcePostID)
            && stops.map(\.place.name) == other.stops.map(\.place.name)
            && stops.map(\.start) == other.stops.map(\.start)
            && stops.map(\.durationMinutes) == other.stops.map(\.durationMinutes)
            && legs.map(\.mode) == other.legs.map(\.mode)
            && abs(cost - other.cost) < 0.005
    }
}

/// Turns saved places into at most three plans for an empty Today (SP-1 to SP-9, SP-19, SP-20).
///
/// It tries small groups of saved places that are near each other, plans each group with the same
/// `DayPlanner` that builds plans by hand (so opening hours, budget, travel time and fares follow the
/// same rules), scores the results and keeps the best few that don't share a stop. Pure: the same
/// saves, settings and start always give the same suggestions in the same order.
struct PlanSuggester {
    var planner: DayPlanner
    var maxSuggestions = 3
    var groupSize = 2...4
    /// Only this many of the most recent saves are tried, so the work stays bounded (SP-17).
    var maxCandidates = 40

    /// A walk between stops is at most this long (SP-6), the same distance the planner walks.
    static let maxWalkMiles = 1.2
    /// "One subway ride" between stops: a short hop, not a trip across town (SP-6).
    static let maxRideMiles = 3.0
    /// A plan with a save older than this ranks below every plan without one (SP-20).
    static let oldSaveDays = 90

    // Score weights. Higher is better; each term has its own test.
    /// For a third stop. A fourth adds nothing more.
    static let thirdStopWeight = 30.0
    /// For food plus something else.
    static let mixWeight = 20.0
    /// Taken off per day of the saves' average age.
    static let agePerDayWeight = 0.5
    /// Taken off per minute of travel.
    static let travelPerMinuteWeight = 0.5
    /// Added per dollar left in the budget.
    static let moneyLeftPerDollarWeight = 0.25

    /// Compared in order: no save older than 90 days, then the weighted sum, then the lower id.
    /// `a < b` means `a` ranks below `b`.
    struct Score: Comparable {
        var hasOldSave: Bool
        var value: Double
        var id: String

        static func < (lhs: Score, rhs: Score) -> Bool {
            if lhs.hasOldSave != rhs.hasOldSave { return lhs.hasOldSave }
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.id > rhs.id
        }
    }

    /// Up to `maxSuggestions` plans from `posts`, best first, that start at `start`, end by `end`,
    /// and cost at most `budget` (including `alreadySpent`, the day's other costs).
    func suggestions(
        posts: [SavedPost], excluding: Set<UUID>, start: Date, budget: Double, end: Date, alreadySpent: Double = 0
    ) -> [PlanSuggestion] {
        let calendar = planner.calendar

        // 1. Candidates: saved places on the map, not in today and not probably over, newest first.
        let newestFirst = posts
            .filter { $0.isMappable && !excluding.contains($0.id) }
            .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.id.uuidString < $1.id.uuidString }
        var picked: [PlanCandidate] = []
        var savedAt: [UUID: Date] = [:]
        for post in newestFirst where picked.count < maxCandidates {
            guard !SaveFreshness.isProbablyOver(post, now: start, calendar: calendar),
                  var candidate = PlanCandidate(post: post) else { continue }
            // The post's id, so the same saves always plan the same way.
            candidate.id = post.id
            picked.append(candidate)
            savedAt[post.id] = post.savedAt
        }
        guard picked.count >= groupSize.lowerBound else { return [] }

        // 2. Groups: each place with its nearest neighbors, 1 to 3 of them.
        let count = picked.count
        let keys = picked.map(\.id.uuidString)
        var miles = Array(repeating: Array(repeating: 0.0, count: count), count: count)
        for i in 0..<count {
            for j in 0..<count where j > i {
                let distance = TravelLeg.streetMiles(from: picked[i].place, to: picked[j].place)
                miles[i][j] = distance
                miles[j][i] = distance
            }
        }
        var groups: [[Int]] = []
        var seenGroups = Set<[Int]>()
        for seed in 0..<count {
            let near = (0..<count)
                .filter { $0 != seed && isClose(miles: miles[seed][$0]) }
                .sorted { (miles[seed][$0], keys[$0]) < (miles[seed][$1], keys[$1]) }
            for size in groupSize where size - 1 <= near.count {
                // In id order, so the planner's tie-breaks never depend on the order of the saves.
                let group = ([seed] + near.prefix(size - 1)).sorted { keys[$0] < keys[$1] }
                if seenGroups.insert(group).inserted { groups.append(group) }
            }
        }

        // 3. Plan each group; keep plans that start on time and keep their stops close.
        let today = calendar.startOfDay(for: start)
        var ranked: [(score: Score, suggestion: PlanSuggestion)] = []
        var seenPlans = Set<String>()
        for group in groups {
            let request = DayPlanner.Request(
                candidates: group.map { picked[$0] }, start: start, budget: budget, alreadySpent: alreadySpent, dayEnd: end
            )
            let outcome = planner.plan(request)
            guard groupSize.contains(outcome.stops.count), fits(outcome, start: start, end: end, budget: budget, alreadySpent: alreadySpent)
            else { continue }
            let postIDs = outcome.stops.compactMap(\.sourcePostID)
            let id = postIDs.map(\.uuidString).joined(separator: ",")
            guard seenPlans.insert(id).inserted else { continue }
            let ages = postIDs.map { postID in
                savedAt[postID].map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: today).day ?? 0 } ?? 0
            }
            ranked.append((
                Self.score(outcome, ageInDays: ages.map { max(0, $0) }, budget: budget, alreadySpent: alreadySpent, id: id),
                PlanSuggestion(id: id, postIDs: postIDs, outcome: outcome, title: Self.title(for: outcome.stops))
            ))
        }

        // 4 and 5. Best first; no stop in two suggestions (two posts about one place are one stop).
        ranked.sort { $0.score > $1.score }
        var result: [PlanSuggestion] = []
        var usedPosts = Set<UUID>()
        var usedPlaces = Set<String>()
        for (_, suggestion) in ranked where result.count < maxSuggestions {
            let places = suggestion.outcome.stops.map(\.place.planKey)
            guard usedPosts.isDisjoint(with: suggestion.postIDs), usedPlaces.isDisjoint(with: places) else { continue }
            usedPosts.formUnion(suggestion.postIDs)
            usedPlaces.formUnion(places)
            result.append(suggestion)
        }
        return result
    }

    /// A walk, or one short subway ride when the student's travel setting allows it (SP-6).
    private func isClose(miles: Double) -> Bool {
        miles <= Self.maxWalkMiles || (planner.travel == .walkAndTransit && miles <= Self.maxRideMiles)
    }

    private func isAllowed(_ leg: TravelLeg) -> Bool {
        switch leg.mode {
        case .walk: leg.miles <= Self.maxWalkMiles
        case .subway, .bus: planner.travel == .walkAndTransit && leg.miles <= Self.maxRideMiles
        case .drive: false
        }
    }

    /// Starts at the start time (SP-4), ends in the window, stays on budget (SP-3), stops close (SP-6).
    private func fits(_ outcome: DayPlanner.Outcome, start: Date, end: Date, budget: Double, alreadySpent: Double) -> Bool {
        guard let first = outcome.stops.first, let last = outcome.end else { return false }
        // The planner rounds the first arrival up to five minutes.
        return first.start >= start && first.start.timeIntervalSince(start) < 5 * 60
            && last <= end
            && alreadySpent + outcome.cost <= budget + 0.005
            && outcome.legs.allSatisfy(isAllowed)
    }

    /// How good a plan is (see the weights above). `ageInDays` has one entry per stop.
    static func score(_ outcome: DayPlanner.Outcome, ageInDays: [Int], budget: Double, alreadySpent: Double, id: String) -> Score {
        let stops = outcome.stops.count
        let hasFood = outcome.stops.contains { $0.place.category.isFood }
        let hasOther = outcome.stops.contains { !$0.place.category.isFood }
        let averageAge = ageInDays.isEmpty ? 0 : Double(ageInDays.reduce(0, +)) / Double(ageInDays.count)
        var value = thirdStopWeight * Double(min(stops, 3) - 2)
        if hasFood && hasOther { value += mixWeight }
        value -= agePerDayWeight * averageAge
        value -= travelPerMinuteWeight * Double(outcome.travelMinutes)
        value += moneyLeftPerDollarWeight * (budget - alreadySpent - outcome.cost)
        return Score(hasOldSave: ageInDays.contains { $0 > oldSaveDays }, value: value, id: id)
    }

    /// "Chelsea", "Chelsea and Flatiron", "Chelsea, Flatiron and SoHo"; the first stop's name when
    /// no stop has a neighborhood.
    static func title(for stops: [PlanStop]) -> String {
        var names: [String] = []
        for stop in stops {
            let name = stop.place.neighborhood.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        switch names.count {
        case 0: return stops.first?.place.name ?? ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

extension PlaceCategory {
    /// Somewhere to eat or drink, for the "food and something else" mix.
    var isFood: Bool { self == .food || self == .coffee }
}

private extension Place {
    /// The planner treats the same name at the same address as one stop.
    var planKey: String { "\(name.lowercased())|\(address.lowercased())" }
}
