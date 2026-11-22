import CoreLocation
import Foundation

/// "Let friends suggest swaps" (group plans, GV-9): for each stop still ahead, up to two of the
/// organizer's own saved places a friend could pick instead. Never a place they didn't save.
enum SwapOptions {
    static let maxPerStop = 2
    /// As the crow flies, from the stop.
    static let maxMiles = 1.2

    /// Saves that could stand in for `stop`, nearest first: the same kind of place, within
    /// `maxMiles`, open for a visit at the stop's time, not already in the plan, and not taking the
    /// plan over its budget (on a plan already over, not costing more than the stop).
    static func pick(for stop: PlanStop, saves: [SavedPost], plan: DayPlan, calendar: Calendar = .current) -> [SavedPost] {
        let inPlanPosts = Set(plan.stops.compactMap(\.sourcePostID))
        var inPlanPlaces = Set(plan.stops.map { placeKey($0.place) })
        let allowedTotal = max(plan.budget, plan.totalCost) + 0.005
        let origin = CLLocation(latitude: stop.place.latitude, longitude: stop.place.longitude)

        var options: [(post: SavedPost, miles: Double)] = []
        for post in saves {
            guard post.isMappable, let place = post.place, !inPlanPosts.contains(post.id),
                  place.category == stop.place.category else { continue }
            let miles = origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) / 1609.34
            guard miles <= maxMiles else { continue }
            let cost = post.plannedCost ?? 0
            guard plan.totalCost - stop.estimatedCost + cost <= allowedTotal else { continue }
            guard isOpen(place, at: stop.start, durationMinutes: stop.durationMinutes, calendar: calendar) else { continue }
            options.append((post, miles))
        }
        options.sort { $0.miles < $1.miles }

        var picked: [SavedPost] = []
        for option in options where picked.count < maxPerStop {
            guard let place = option.post.place, inPlanPlaces.insert(placeKey(place)).inserted else { continue }
            picked.append(option.post)
        }
        return picked
    }

    /// Every stop still ahead that has any, keyed by stop id. Stops done or underway get none.
    static func all(for plan: DayPlan, saves: [SavedPost], calendar: Calendar = .current) -> [UUID: [SavedPost]] {
        var result: [UUID: [SavedPost]] = [:]
        for stop in plan.stops where stop.status == .upcoming {
            let picked = pick(for: stop, saves: saves, plan: plan, calendar: calendar)
            if !picked.isEmpty { result[stop.id] = picked }
        }
        return result
    }

    /// Open long enough for a short visit from `start`, the same rule the planner uses. Hours that
    /// don't say when the place closes count as open; evening-only places wait for the evening.
    private static func isOpen(_ place: Place, at start: Date, durationMinutes: Int, calendar: Calendar) -> Bool {
        var arrival = start
        if let opens = place.category.earliestStartMinutes,
           let evening = calendar.date(byAdding: .minute, value: opens, to: calendar.startOfDay(for: start)) {
            arrival = max(arrival, evening)
        }
        guard let close = place.closingTime(on: start, calendar: calendar) else { return true }
        let stay = TimeInterval(min(DayPlanner.minimumStayMinutes, durationMinutes) * 60)
        return arrival.addingTimeInterval(stay) <= close
    }

    /// The same place saved twice (two posts about one spot) is one option.
    private static func placeKey(_ place: Place) -> String {
        "\(place.name.lowercased())|\(place.address.lowercased())"
    }
}
