import CoreLocation
import Foundation

/// A place the user wants in their day, before the planner gives it a time.
struct PlanCandidate: Identifiable, Hashable {
    /// Becomes the stop's id, so a stop keeps its identity when the day is re-planned.
    var id: UUID
    var place: Place
    var cost: Double
    var durationMinutes: Int
    var sourcePostID: UUID?
    var note: String?

    init(id: UUID = UUID(), place: Place, cost: Double, durationMinutes: Int? = nil, sourcePostID: UUID? = nil, note: String? = nil) {
        self.id = id
        self.place = place
        self.cost = max(0, cost)
        self.durationMinutes = max(5, durationMinutes ?? place.category.typicalVisitMinutes)
        self.sourcePostID = sourcePostID
        self.note = note
    }

    /// A saved post with a place; nil if it hasn't been mapped yet.
    init?(post: SavedPost) {
        guard post.isMappable, let place = post.place else { return nil }
        self.init(
            place: place,
            cost: post.estimatedCost ?? 0,
            sourcePostID: post.id,
            note: "Added from your saved \(post.platform.displayName) post."
        )
    }

    /// A stop that's already in the plan, so it can be re-ordered with new ones.
    init(stop: PlanStop) {
        self.init(id: stop.id, place: stop.place, cost: stop.estimatedCost, durationMinutes: stop.durationMinutes,
                  sourcePostID: stop.sourcePostID, note: stop.note)
    }
}

/// How the planner may move you between stops (Profile → Getting around).
enum TravelPreference: Equatable {
    case walkOnly, walkAndTransit

    init(setting: String) {
        let setting = setting.lowercased()
        self = setting.contains("subway") || setting.contains("bus") ? .walkAndTransit : .walkOnly
    }
}

extension PlaceCategory {
    /// How long a visit usually takes when the post doesn't say.
    var typicalVisitMinutes: Int {
        switch self {
        case .food: 45
        case .coffee: 45
        case .activity: 60
        case .outdoors: 75
        case .culture: 120
        case .nightlife: 90
        case .shopping: 45
        }
    }

    /// Places that only make sense in the evening don't start before this time (minutes after midnight).
    var earliestStartMinutes: Int? {
        self == .nightlife ? 20 * 60 : nil
    }
}

extension Place {
    /// When the place closes on `day`, read from hours like "Open until 9 PM", "Runs until 2 AM" or
    /// "Open until midnight". Nil when the hours don't say ("Open late", "Shows at 7:30 PM", none).
    func closingTime(on day: Date, calendar: Calendar = .current) -> Date? {
        guard let hours = hours?.lowercased(), let range = hours.range(of: "until ") else { return nil }
        let rest = hours[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let startOfDay = calendar.startOfDay(for: day)

        var hour: Int
        var minute = 0
        if rest.hasPrefix("midnight") {
            hour = 24
        } else if rest.hasPrefix("noon") {
            hour = 12
        } else if let match = rest.firstMatch(of: #/^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)/#) {
            guard let parsedHour = Int(match.1), (1...12).contains(parsedHour) else { return nil }
            hour = parsedHour % 12 + (match.3.hasPrefix("p") ? 12 : 0)
            minute = match.2.flatMap { Int($0) } ?? 0
            // "Until 2 AM" means the early hours of the next day.
            if hour < 6 { hour += 24 }
        } else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: startOfDay)
    }
}

/// Turns a handful of saved places into a day: picks the order with the least travel, gives each stop
/// a time, keeps visits inside opening hours, and stays on budget. Anything that can't fit is left out
/// with a reason, never silently dropped.
struct DayPlanner {
    var travel: TravelPreference = .walkAndTransit
    var calendar: Calendar = .current

    /// Shortest visit worth making before a place closes.
    static let minimumStayMinutes = 30
    /// Up to this many stops every order is tried; above it, a fast search that's nearly always as good.
    var exactSearchLimit = 7

    struct Request {
        var candidates: [PlanCandidate]
        var start: Date
        var budget: Double
        /// The stop the user is at or just finished. New stops follow it, starting when it ends.
        var anchor: PlanStop?
        /// Money already spent on earlier stops today; counts against the budget.
        var alreadySpent: Double = 0
        /// Nothing may run past this. Defaults to 2 AM after the start day.
        var dayEnd: Date?
    }

    enum SkipReason: Equatable {
        case closed, overBudget, outOfTime
        /// An evening-only place (nightlife) when the day ends before evening.
        case eveningOnly
    }

    struct Skip: Hashable {
        var candidate: PlanCandidate
        var reason: SkipReason
    }

    struct Outcome {
        var stops: [PlanStop]
        /// Travel between stops, including the leg from the anchor when there is one.
        var legs: [TravelLeg]
        var skipped: [Skip]

        var cost: Double { stops.reduce(0) { $0 + $1.estimatedCost } + legs.reduce(0) { $0 + $1.cost } }
        var travelMinutes: Int { legs.reduce(0) { $0 + $1.minutes } }
        var walkingMiles: Double { legs.filter { $0.mode == .walk }.reduce(0) { $0 + $1.miles } }
        var end: Date? { stops.last?.end }
    }

    func plan(_ request: Request) -> Outcome {
        let dayEnd = request.dayEnd ?? defaultDayEnd(for: request.start)
        var kept: [PlanCandidate] = []
        var skipped: [Skip] = []
        for candidate in deduplicated(request.candidates) {
            if let opens = opening(of: candidate, on: request.start),
               opens.addingTimeInterval(TimeInterval(min(Self.minimumStayMinutes, candidate.durationMinutes) * 60)) > dayEnd {
                skipped.append(Skip(candidate: candidate, reason: .eveningOnly))
            } else {
                kept.append(candidate)
            }
        }

        while !kept.isEmpty {
            let problem = Problem(candidates: kept, request: request, travel: travel, calendar: calendar, exactSearchLimit: exactSearchLimit)
            let order = problem.bestOrder()
            let schedule = problem.schedule(order)

            // 1. A place that's closed whatever the order.
            if let worst = schedule.lateness.indices.filter({ schedule.lateness[$0] > 0 })
                .max(by: { (schedule.lateness[$0], order[$0]) < (schedule.lateness[$1], order[$1]) }) {
                skipped.append(Skip(candidate: kept.remove(at: order[worst]), reason: .closed))
                continue
            }
            // 2. The day runs too late: drop the stop that frees up the most time.
            if schedule.end > dayEnd {
                let position = problem.positionSavingMost(in: order) { Double($0.durationMinutes) } legValue: { Double($0.minutes) }
                skipped.append(Skip(candidate: kept.remove(at: order[position]), reason: .outOfTime))
                continue
            }
            // 3. Over budget: drop the stop that saves the most money.
            if request.alreadySpent + schedule.cost > request.budget + 0.005 {
                let position = problem.positionSavingMost(in: order) { $0.cost } legValue: { $0.cost }
                skipped.append(Skip(candidate: kept.remove(at: order[position]), reason: .overBudget))
                continue
            }
            return problem.outcome(order: order, schedule: schedule, skipped: skipped)
        }
        return Outcome(stops: [], legs: [], skipped: skipped)
    }

    /// The earliest a place should start, for evening-only places; nil when any time works.
    func opening(of candidate: PlanCandidate, on day: Date) -> Date? {
        candidate.place.category.earliestStartMinutes.flatMap {
            calendar.date(byAdding: .minute, value: $0, to: calendar.startOfDay(for: day))
        }
    }

    private func defaultDayEnd(for start: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: start)
        return calendar.date(byAdding: .hour, value: 26, to: startOfDay) ?? start.addingTimeInterval(26 * 3600)
    }

    /// The same place picked twice (e.g. two posts about one spot) becomes one stop.
    private func deduplicated(_ candidates: [PlanCandidate]) -> [PlanCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert("\($0.place.name.lowercased())|\($0.place.address.lowercased())").inserted }
    }
}

// MARK: - Search

/// One planning attempt over a fixed set of candidates.
private struct Problem {
    let candidates: [PlanCandidate]
    let request: DayPlanner.Request
    let travel: TravelPreference
    /// legs[i][j]: travel from candidate i to j.
    let legs: [[TravelLeg]]
    /// fromAnchor[j]: travel from the anchor stop to candidate j.
    let fromAnchor: [TravelLeg]?
    let closes: [Date?]
    let opens: [Date?]
    let exactSearchLimit: Int

    init(candidates: [PlanCandidate], request: DayPlanner.Request, travel: TravelPreference, calendar: Calendar, exactSearchLimit: Int) {
        self.candidates = candidates
        self.exactSearchLimit = exactSearchLimit
        self.request = request
        self.travel = travel
        legs = candidates.map { a in
            candidates.map { b in TravelLeg.estimate(from: a.place, to: b.place, fromStopID: a.id, toStopID: b.id, travel: travel) }
        }
        fromAnchor = request.anchor.map { anchor in
            candidates.map { TravelLeg.estimate(from: anchor.place, to: $0.place, fromStopID: anchor.id, toStopID: $0.id, travel: travel) }
        }
        closes = candidates.map { $0.place.closingTime(on: request.start, calendar: calendar) }
        let planner = DayPlanner(calendar: calendar)
        opens = candidates.map { planner.opening(of: $0, on: request.start) }
    }

    struct Schedule {
        var starts: [Date] = []
        var durations: [Int] = []
        /// Minutes short of a minimum visit before closing, per position in the order.
        var lateness: [Int] = []
        var travelMinutes = 0
        /// Time spent waiting for an evening place to get going.
        var waitMinutes = 0
        var cost: Double = 0
        var end: Date

        /// Lower is better: being late to a closing place outweighs any amount of travel.
        /// Travel counts double: before a fixed evening start, travel + waiting adds up to the same total
        /// in every order, so weighing them equally would stop the planner caring about travel at all.
        var score: Int { lateness.reduce(0, +) * 10_000 + travelMinutes * 2 + waitMinutes }
    }

    func leg(into position: Int, of order: [Int]) -> TravelLeg? {
        if position == 0 { return fromAnchor?[order[0]] }
        return legs[order[position - 1]][order[position]]
    }

    func schedule(_ order: [Int]) -> Schedule {
        var clock = request.anchor?.end ?? request.start
        var schedule = Schedule(end: clock)
        for position in order.indices {
            let candidate = candidates[order[position]]
            if let leg = leg(into: position, of: order) {
                clock = clock.addingTimeInterval(TimeInterval(leg.minutes * 60))
                schedule.travelMinutes += leg.minutes
                schedule.cost += leg.cost
            }
            var arrival = clock.roundedUpToFiveMinutes
            if let opens = opens[order[position]], arrival < opens {
                schedule.waitMinutes += Int(opens.timeIntervalSince(arrival) / 60)
                arrival = opens
            }
            var duration = candidate.durationMinutes
            var late = 0
            if let close = closes[order[position]] {
                let available = Int(close.timeIntervalSince(arrival) / 60)
                let needed = min(DayPlanner.minimumStayMinutes, duration)
                if available < needed {
                    late = needed - available
                } else {
                    duration = min(duration, available) // a shorter visit that ends at closing
                }
            }
            schedule.starts.append(arrival)
            schedule.durations.append(duration)
            schedule.lateness.append(late)
            schedule.cost += candidate.cost
            clock = arrival.addingTimeInterval(TimeInterval(duration * 60))
        }
        schedule.end = clock
        return schedule
    }

    /// The order with the lowest score. Ties keep the order the user picked things in.
    func bestOrder() -> [Int] {
        let n = candidates.count
        guard n > 1 else { return Array(0..<n) }
        return n <= exactSearchLimit ? exhaustiveOrder() : heuristicOrder()
    }

    private func exhaustiveOrder() -> [Int] {
        var order = Array(candidates.indices)
        var best = order
        var bestScore = schedule(order).score
        while order.advanceToNextPermutation() {
            let score = schedule(order).score
            if score < bestScore {
                best = order
                bestScore = score
            }
        }
        return best
    }

    /// Nearest-neighbor tours from every start (plus the picked order), each polished by 2-opt and
    /// single-stop moves until nothing improves.
    private func heuristicOrder() -> [Int] {
        var seeds = [Array(candidates.indices)]
        for first in candidates.indices {
            var tour = [first]
            var remaining = Set(candidates.indices).subtracting([first])
            while let current = tour.last, !remaining.isEmpty {
                let next = remaining.min { (legs[current][$0].minutes, $0) < (legs[current][$1].minutes, $1) }!
                tour.append(next)
                remaining.remove(next)
            }
            seeds.append(tour)
        }

        var best = seeds[0]
        var bestScore = schedule(best).score
        for seed in seeds {
            let (tour, score) = improve(seed)
            if score < bestScore {
                best = tour
                bestScore = score
            }
        }
        return best
    }

    private func improve(_ start: [Int]) -> ([Int], Int) {
        var tour = start
        var score = schedule(tour).score
        var improved = true
        while improved {
            improved = false
            // 2-opt: reverse a stretch of the route.
            for i in 0..<(tour.count - 1) {
                for j in (i + 1)..<tour.count {
                    var candidate = tour
                    candidate[i...j].reverse()
                    let candidateScore = schedule(candidate).score
                    if candidateScore < score {
                        tour = candidate
                        score = candidateScore
                        improved = true
                    }
                }
            }
            // Move one stop somewhere else in the day.
            for i in tour.indices {
                for j in tour.indices where j != i {
                    var candidate = tour
                    candidate.insert(candidate.remove(at: i), at: j)
                    let candidateScore = schedule(candidate).score
                    if candidateScore < score {
                        tour = candidate
                        score = candidateScore
                        improved = true
                    }
                }
            }
        }
        return (tour, score)
    }

    /// The position whose removal saves the most (its own value plus the legs around it, minus the
    /// leg that would replace them). Ties drop the stop picked last.
    func positionSavingMost(in order: [Int], stopValue: (PlanCandidate) -> Double, legValue: (TravelLeg) -> Double) -> Int {
        func saving(_ position: Int) -> Double {
            var saved = stopValue(candidates[order[position]])
            if let into = leg(into: position, of: order) { saved += legValue(into) }
            if position + 1 < order.count {
                saved += legValue(legs[order[position]][order[position + 1]])
                if position > 0 {
                    saved -= legValue(legs[order[position - 1]][order[position + 1]])
                } else if let anchorLeg = fromAnchor?[order[position + 1]] {
                    saved -= legValue(anchorLeg)
                }
            }
            return saved
        }
        return order.indices.max { (saving($0), order[$0]) < (saving($1), order[$1]) }!
    }

    func outcome(order: [Int], schedule: Schedule, skipped: [DayPlanner.Skip]) -> DayPlanner.Outcome {
        let stops = order.indices.map { position in
            let candidate = candidates[order[position]]
            var note = candidate.note
            if let close = closes[order[position]],
               close.timeIntervalSince(schedule.starts[position]) <= TimeInterval((schedule.durations[position] + 60) * 60) {
                note = [note, "Goes here before it closes at \(close.shortTime)."].compactMap { $0 }.joined(separator: " ")
            }
            if let opens = opens[order[position]] {
                note = [note, "It's an evening spot, so it starts after \(opens.shortTime)."].compactMap { $0 }.joined(separator: " ")
            }
            return PlanStop(
                id: candidate.id,
                place: candidate.place,
                start: schedule.starts[position],
                durationMinutes: schedule.durations[position],
                estimatedCost: candidate.cost,
                note: note,
                sourcePostID: candidate.sourcePostID,
                status: .upcoming
            )
        }
        let planLegs = order.indices.compactMap { leg(into: $0, of: order) }
        return DayPlanner.Outcome(stops: stops, legs: planLegs, skipped: skipped)
    }
}

private extension Date {
    var roundedUpToFiveMinutes: Date {
        let step: TimeInterval = 5 * 60
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }
}

private extension Array where Element == Int {
    /// Lexicographic next permutation; false once the last one has been reached.
    mutating func advanceToNextPermutation() -> Bool {
        guard count > 1 else { return false }
        var i = count - 2
        while i >= 0, self[i] >= self[i + 1] { i -= 1 }
        guard i >= 0 else { return false }
        var j = count - 1
        while self[j] <= self[i] { j -= 1 }
        swapAt(i, j)
        self[(i + 1)...].reverse()
        return true
    }
}
