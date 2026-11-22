import Foundation

/// Whose inputs: the organizer's, or a friend's answer.
nonisolated enum GroupMember: Hashable, Sendable {
    case organizer
    case friend(UUID)
}

/// Friends' answers on an "Ask friends what works" link, turned into the planner's inputs (group
/// plans, mode 2; GI-5, GI-6).
nonisolated enum GroupInputs {
    struct Person: Equatable {
        var member: GroupMember
        var budget: Double
        var from: ClockTime
        var until: ClockTime
        var stars: [UUID]
    }

    struct Candidate: Equatable {
        var placeID: UUID
        /// How many people starred it: the planner's priority.
        var stars: Int
    }

    struct Plan: Equatable {
        var start: ClockTime
        var end: ClockTime
        var budget: Double
        var candidates: [Candidate]
    }

    enum Result: Equatable {
        case ready(Plan)
        /// The times don't overlap by an hour: these people's times clash, in answer order.
        case clash([GroupMember])
    }

    static let minimumOverlapMinutes = 60
    static let maxCandidates = 7

    /// Everyone's inputs together: the plan runs from the latest "from" to the earliest "until" of
    /// everyone whose times count, on the lowest budget of all (GI-5), through the most-starred
    /// places first: at most `maxCandidates`, so the planner still tries every order. Ties keep the
    /// organizer's order, and unstarred places fill what's left.
    ///
    /// When the times don't overlap by at least `minimumOverlapMinutes` it plans nothing and names
    /// whose times clash (GI-6): everyone outside the biggest group that has an hour together (or
    /// outside each of the biggest, when several tie). The organizer can then leave friends out of
    /// the times (`leftOut`): their budget and stars still count, so the plan stays affordable for
    /// them. The organizer's own times always count; they change them instead.
    static func combine(answers: [GroupAnswer], organizer: Person, places: [UUID], leftOut: Set<GroupMember> = []) -> Result {
        let people = [organizer] + answers.map {
            Person(member: .friend($0.id), budget: Double($0.budget), from: $0.freeFrom, until: $0.freeUntil, stars: $0.stars)
        }
        let timed = people.filter { $0.member == .organizer || !leftOut.contains($0.member) }

        let named = clashing(timed)
        guard named.isEmpty else { return .clash(named) }

        let start = timed.map(\.from).max() ?? organizer.from
        let end = timed.map(\.until).min() ?? organizer.until
        let budget = people.map(\.budget).min() ?? organizer.budget
        return .ready(Plan(start: start, end: end, budget: budget, candidates: candidates(people, places: places)))
    }

    /// The members outside every biggest group that shares an hour, in `people`'s order; none when
    /// everyone does. A shared hour can always start at someone's "from", so those are the only
    /// starts to try.
    private static func clashing(_ people: [Person]) -> [GroupMember] {
        var best: [Set<GroupMember>] = []
        var bestCount = 0
        for start in Set(people.map(\.from.minutes)) {
            let end = start + minimumOverlapMinutes
            let group = Set(people.filter { $0.from.minutes <= start && $0.until.minutes >= end }.map(\.member))
            if group.count > bestCount {
                best = [group]
                bestCount = group.count
            } else if group.count == bestCount, !best.contains(group) {
                best.append(group)
            }
        }
        guard bestCount < people.count else { return [] }
        let together = best.dropFirst().reduce(best.first ?? []) { $0.intersection($1) }
        return people.map(\.member).filter { !together.contains($0) }
    }

    /// The request's places, most stars first, at most `maxCandidates`. A person's star counts once
    /// per place, and stars on places the request doesn't have are ignored.
    private static func candidates(_ people: [Person], places: [UUID]) -> [Candidate] {
        let offered = Set(places)
        var counts: [UUID: Int] = [:]
        for person in people {
            for place in Set(person.stars) where offered.contains(place) { counts[place, default: 0] += 1 }
        }
        var seen = Set<UUID>()
        let ordered = places.filter { seen.insert($0).inserted }.enumerated()
            .sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }
        return ordered.prefix(maxCandidates).map { Candidate(placeID: $0.element, stars: counts[$0.element] ?? 0) }
    }
}
