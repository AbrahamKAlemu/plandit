import CoreLocation
import Foundation

/// One Plandit day: an ordered set of stops with the travel between them.
struct DayPlan: Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var budget: Double
    var stops: [PlanStop]
    var legs: [TravelLeg]
}

struct PlanStop: Identifiable, Hashable {
    var id = UUID()
    var place: Place
    var start: Date
    var durationMinutes: Int
    var estimatedCost: Double
    /// Why the planner picked this stop.
    var note: String?
    /// The saved TikTok/Reel this stop came from, if any.
    var sourcePostID: UUID?
    var status: StopStatus

    var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
}

enum StopStatus: String, Codable {
    case done, now, upcoming

    var label: String {
        switch self {
        case .done: "Done"
        case .now: "Now"
        case .upcoming: "Planned"
        }
    }
}

struct TravelLeg: Identifiable, Hashable {
    var id = UUID()
    var fromStopID: UUID
    var toStopID: UUID
    var mode: TravelMode
    var minutes: Int
    var miles: Double
    var cost: Double = 0
    /// Line name for transit, e.g. "Q train" or "M4 bus".
    var detail: String?

    /// "Walk · 18 min · 0.9 mi" or "M4 bus · 28 min · $2.90".
    var summary: String {
        switch mode {
        case .walk:
            "Walk · \(minutes) min · \(miles.milesText)"
        case .subway, .bus:
            [detail ?? mode.label, "\(minutes) min", cost.dollarsText].joined(separator: " · ")
        }
    }

    /// Rough leg until the real planner fills it in: walk under ~1.2 mi, otherwise subway.
    static func estimate(from a: PlanStop, to b: PlanStop) -> TravelLeg {
        let meters = CLLocation(latitude: a.place.latitude, longitude: a.place.longitude)
            .distance(from: CLLocation(latitude: b.place.latitude, longitude: b.place.longitude))
        let miles = meters / 1609.34 * 1.25 // street-grid detour factor
        if miles <= 1.2 {
            return TravelLeg(fromStopID: a.id, toStopID: b.id, mode: .walk, minutes: max(3, Int((miles * 20).rounded())), miles: miles)
        }
        return TravelLeg(fromStopID: a.id, toStopID: b.id, mode: .subway, minutes: 10 + Int((miles * 4).rounded()), miles: miles, cost: 2.90, detail: "Subway")
    }
}

enum TravelMode: String, Codable {
    case walk, subway, bus

    var label: String {
        switch self {
        case .walk: "Walk"
        case .subway: "Subway"
        case .bus: "Bus"
        }
    }

    var icon: Lucide {
        switch self {
        case .walk: .footprints
        case .subway: .trainFront
        case .bus: .bus
        }
    }
}

/// Where a leg sits relative to "now", used for route color on the map and timeline.
enum LegState {
    case completed, active, upcoming
}

extension DayPlan {
    var totalCost: Double {
        stops.reduce(0) { $0 + $1.estimatedCost } + legs.reduce(0) { $0 + $1.cost }
    }

    var walkingMiles: Double {
        legs.filter { $0.mode == .walk }.reduce(0) { $0 + $1.miles }
    }

    var nextStop: PlanStop? { stops.first { $0.status == .upcoming } }

    var savedPostCount: Int { stops.compactMap(\.sourcePostID).count }

    func stop(id: UUID) -> PlanStop? { stops.first { $0.id == id } }

    func leg(after stop: PlanStop) -> TravelLeg? { legs.first { $0.fromStopID == stop.id } }

    func state(of leg: TravelLeg) -> LegState {
        let to = stop(id: leg.toStopID)?.status
        if to == .done || to == .now { return .completed }
        if stop(id: leg.fromStopID)?.status == .now { return .active }
        return .upcoming
    }

    var shareText: String {
        let lines = stops.map { "\($0.start.shortTime) · \($0.place.name)" }
        return (["My Plandit day: \(title)"] + lines + ["About \(totalCost.wholeDollarsText) total"]).joined(separator: "\n")
    }
}
