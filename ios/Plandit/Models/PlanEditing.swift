import Foundation

/// Changing a plan that's already made: fitting in one more place, and putting stops in a new order.
/// Stops that are done or underway never move.
extension DayPlan {
    /// The first stop that can still move. Everything before it is done or underway.
    var firstMovableIndex: Int {
        stops.lastIndex { $0.status != .upcoming }.map { $0 + 1 } ?? 0
    }

    /// Keeps the trip between two stops that are still next to each other (with the way the user
    /// picked to make it) and estimates trips between new neighbors.
    mutating func relinkLegs(travel: TravelPreference) {
        let existing = legs
        legs = zip(stops, stops.dropFirst()).map { from, to in
            existing.first { $0.fromStopID == from.id && $0.toStopID == to.id } ?? .estimate(from: from, to: to, travel: travel)
        }
    }

    // MARK: - Adding one place

    struct Insertion {
        var plan: DayPlan
        var position: Int
        /// Minutes short of a 30-minute visit before the new place closes; 0 when it fits.
        var lateMinutes: Int
        /// Stops already in the plan that it would make you reach after they close.
        var newlyLateStops: [PlanStop]
        /// Lower is better.
        var score: Int

        var stop: PlanStop { plan.stops[position] }
    }

    /// Fits a place into the part of the day still ahead. Every open slot is tried; the best one
    /// gets you there while it's open, keeps everything else open too, and adds the least travel
    /// and the least time to the day. Ties go to the latest slot, which moves the fewest stops.
    /// Stops after it only move as much as they have to.
    func inserting(_ candidate: PlanCandidate, travel: TravelPreference, now: Date = .now, calendar: Calendar = .current) -> Insertion {
        let alreadyLate = Set(stopsArrivingAfterClose(calendar: calendar).map(\.id))
        var best: Insertion?
        for position in (firstMovableIndex...stops.count).reversed() {
            let trial = trialInsert(candidate, at: position, travel: travel, now: now, calendar: calendar, alreadyLate: alreadyLate)
            if best.map({ trial.score < $0.score }) ?? true { best = trial }
        }
        return best!
    }

    private func trialInsert(
        _ candidate: PlanCandidate, at position: Int, travel: TravelPreference,
        now: Date, calendar: Calendar, alreadyLate: Set<UUID>
    ) -> Insertion {
        var plan = self
        plan.stops.insert(PlanStop(
            id: candidate.id, place: candidate.place, start: now, durationMinutes: candidate.durationMinutes,
            estimatedCost: candidate.cost, note: candidate.note, sourcePostID: candidate.sourcePostID,
            status: .upcoming, costItems: candidate.costItems, costIsCustom: candidate.costIsCustom
        ), at: position)
        plan.relinkLegs(travel: travel)

        var start: Date
        if position > 0 {
            let previous = plan.stops[position - 1]
            start = previous.end.addingTimeInterval(TimeInterval((plan.leg(after: previous)?.minutes ?? 0) * 60))
        } else {
            start = stops.first?.start ?? now
        }
        if stops.isEmpty || calendar.isDate(date, inSameDayAs: now) { start = max(start, now) }
        start = Self.evening(start, for: candidate.place, calendar: calendar).roundedUpToFiveMinutes

        var duration = candidate.durationMinutes
        var late = 0
        if let close = candidate.place.closingTime(on: start, calendar: calendar) {
            let available = Int(close.timeIntervalSince(start) / 60)
            let needed = min(DayPlanner.minimumStayMinutes, duration)
            if available < needed { late = needed - available }
            // Never past closing; the user still sees how short the visit got.
            if available > 0 { duration = min(duration, available) }
        }
        plan.stops[position].start = start
        plan.stops[position].durationMinutes = duration
        plan.shiftStops(from: position + 1, by: 0, calendar: calendar)

        let newlyLate = plan.stopsArrivingAfterClose(calendar: calendar).filter { $0.id != candidate.id && !alreadyLate.contains($0.id) }
        let addedTravel = plan.legs.reduce(0) { $0 + $1.minutes } - legs.reduce(0) { $0 + $1.minutes }
        let dayEnd = max(stops.last?.end ?? start, start)
        let addedTime = Int((plan.stops.last?.end ?? start).timeIntervalSince(dayEnd) / 60)
        let score = (late + newlyLate.count * 30) * 10_000 + addedTravel * 2 + addedTime
        return Insertion(plan: plan, position: position, lateMinutes: late, newlyLateStops: newlyLate, score: score)
    }

    // MARK: - Reordering

    /// The stops still ahead in a new order. They're retimed one after another from when the first
    /// of them was due to start (or when the stop before it ends and you get there, if later).
    /// Evening spots still wait for 8 PM. Any other `ids` (missing, extra or locked stops) change nothing.
    func reordered(_ ids: [UUID], travel: TravelPreference, calendar: Calendar = .current) -> DayPlan {
        let first = firstMovableIndex
        let movable = Array(stops[first...])
        guard ids.count == movable.count, Set(ids) == Set(movable.map(\.id)), ids != movable.map(\.id),
              let slot = movable.first?.start else { return self }
        var plan = self
        plan.stops = Array(stops[..<first]) + ids.compactMap { id in movable.first { $0.id == id } }
        plan.relinkLegs(travel: travel)
        for index in first..<plan.stops.count {
            var start = index == first ? slot : .distantPast
            if index > 0 {
                let previous = plan.stops[index - 1]
                start = max(start, previous.end.addingTimeInterval(TimeInterval((plan.leg(after: previous)?.minutes ?? 0) * 60)))
            }
            plan.stops[index].start = Self.evening(start, for: plan.stops[index].place, calendar: calendar).roundedUpToFiveMinutes
        }
        return plan
    }

    /// Evening-only places (nightlife) don't start before 8 PM.
    private static func evening(_ start: Date, for place: Place, calendar: Calendar) -> Date {
        guard let opens = place.category.earliestStartMinutes,
              let evening = calendar.date(byAdding: .minute, value: opens, to: calendar.startOfDay(for: start)) else { return start }
        return max(start, evening)
    }
}

private extension Date {
    var roundedUpToFiveMinutes: Date {
        let step: TimeInterval = 5 * 60
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }
}
