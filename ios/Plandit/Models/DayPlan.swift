import CoreLocation
import Foundation

/// One Plandit day: an ordered set of stops with the travel between them.
struct DayPlan: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var title: String
    var budget: Double
    var stops: [PlanStop]
    var legs: [TravelLeg]
    /// Costs that belong to the day, not one stop: "Snacks $8", "Ride home $20".
    var extras: [CostItem] = []

    init(id: UUID = UUID(), date: Date, title: String, budget: Double, stops: [PlanStop], legs: [TravelLeg], extras: [CostItem] = []) {
        self.id = id
        self.date = date
        self.title = title
        self.budget = budget
        self.stops = stops
        self.legs = legs
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey { case id, date, title, budget, stops, legs, extras }

    /// Files and cloud copies from before extras existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        title = try c.decode(String.self, forKey: .title)
        budget = try c.decode(Double.self, forKey: .budget)
        stops = try c.decode([PlanStop].self, forKey: .stops)
        legs = try c.decode([TravelLeg].self, forKey: .legs)
        extras = try c.decodeIfPresent([CostItem].self, forKey: .extras) ?? []
    }
}

struct PlanStop: Identifiable, Hashable, Codable {
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
    /// What the user listed they'll pay for here. When there are any, `estimatedCost` is their total.
    var costItems: [CostItem] = []
    /// The user set this stop's cost themselves, so re-planning keeps it.
    var costIsCustom = false

    init(
        id: UUID = UUID(), place: Place, start: Date, durationMinutes: Int, estimatedCost: Double,
        note: String? = nil, sourcePostID: UUID? = nil, status: StopStatus,
        costItems: [CostItem] = [], costIsCustom: Bool = false
    ) {
        self.id = id
        self.place = place
        self.start = start
        self.durationMinutes = durationMinutes
        self.estimatedCost = estimatedCost
        self.note = note
        self.sourcePostID = sourcePostID
        self.status = status
        self.costItems = costItems
        self.costIsCustom = costIsCustom
    }

    private enum CodingKeys: String, CodingKey {
        case id, place, start, durationMinutes, estimatedCost, note, sourcePostID, status, costItems, costIsCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        place = try c.decode(Place.self, forKey: .place)
        start = try c.decode(Date.self, forKey: .start)
        durationMinutes = try c.decode(Int.self, forKey: .durationMinutes)
        estimatedCost = try c.decode(Double.self, forKey: .estimatedCost)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        sourcePostID = try c.decodeIfPresent(UUID.self, forKey: .sourcePostID)
        status = try c.decode(StopStatus.self, forKey: .status)
        costItems = try c.decodeIfPresent([CostItem].self, forKey: .costItems) ?? []
        costIsCustom = try c.decodeIfPresent(Bool.self, forKey: .costIsCustom) ?? false
    }

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

struct TravelLeg: Identifiable, Hashable, Codable {
    var id = UUID()
    var fromStopID: UUID
    var toStopID: UUID
    var mode: TravelMode
    var minutes: Int
    var miles: Double
    var cost: Double = 0
    /// Line name for transit, e.g. "Q train" or "M4 bus".
    var detail: String?
    /// The user picked this way of getting there, so re-planning keeps it.
    var isChosen = false

    init(
        id: UUID = UUID(), fromStopID: UUID, toStopID: UUID, mode: TravelMode, minutes: Int, miles: Double,
        cost: Double = 0, detail: String? = nil, isChosen: Bool = false
    ) {
        self.id = id
        self.fromStopID = fromStopID
        self.toStopID = toStopID
        self.mode = mode
        self.minutes = minutes
        self.miles = miles
        self.cost = cost
        self.detail = detail
        self.isChosen = isChosen
    }

    private enum CodingKeys: String, CodingKey { case id, fromStopID, toStopID, mode, minutes, miles, cost, detail, isChosen }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fromStopID = try c.decode(UUID.self, forKey: .fromStopID)
        toStopID = try c.decode(UUID.self, forKey: .toStopID)
        mode = try c.decode(TravelMode.self, forKey: .mode)
        minutes = try c.decode(Int.self, forKey: .minutes)
        miles = try c.decode(Double.self, forKey: .miles)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        isChosen = try c.decodeIfPresent(Bool.self, forKey: .isChosen) ?? false
    }

    /// "Walk · 18 min · 0.9 mi", "M4 bus · 28 min · $2.90" or "Drive · 12 min · about $15".
    var summary: String {
        switch mode {
        case .walk:
            "Walk · \(minutes) min · \(miles.milesText)"
        case .subway, .bus:
            [detail ?? mode.label, "\(minutes) min", cost.dollarsText].joined(separator: " · ")
        case .drive:
            "Drive · \(minutes) min · about \(cost.wholeDollarsText)"
        }
    }

    /// Rough leg until the real planner fills it in: walk under ~1.2 mi, otherwise subway.
    static func estimate(from a: PlanStop, to b: PlanStop, travel: TravelPreference = .walkAndTransit) -> TravelLeg {
        estimate(from: a.place, to: b.place, fromStopID: a.id, toStopID: b.id, travel: travel)
    }

    /// Walk-only always walks, however far.
    static func estimate(from a: Place, to b: Place, fromStopID: UUID, toStopID: UUID, travel: TravelPreference) -> TravelLeg {
        let miles = streetMiles(from: a, to: b)
        let mode: TravelMode = miles <= 1.2 || travel == .walkOnly ? .walk : .subway
        return estimate(mode, miles: miles, fromStopID: fromStopID, toStopID: toStopID)
    }

    /// A leg by a given mode when Apple Maps hasn't answered (or can't): straight-line miles on Manhattan's grid.
    /// Drive is a taxi or rideshare: a few minutes to get picked up, about 13 mph, and roughly $4 + $3.50 a mile.
    static func estimate(_ mode: TravelMode, miles: Double, fromStopID: UUID, toStopID: UUID) -> TravelLeg {
        switch mode {
        case .walk:
            TravelLeg(fromStopID: fromStopID, toStopID: toStopID, mode: .walk, minutes: max(3, Int((miles * 20).rounded())), miles: miles)
        case .subway:
            TravelLeg(fromStopID: fromStopID, toStopID: toStopID, mode: .subway, minutes: 10 + Int((miles * 4).rounded()), miles: miles, cost: TravelMode.fare, detail: "Subway")
        case .bus:
            TravelLeg(fromStopID: fromStopID, toStopID: toStopID, mode: .bus, minutes: 8 + Int((miles * 7).rounded()), miles: miles, cost: TravelMode.fare, detail: "Bus")
        case .drive:
            TravelLeg(fromStopID: fromStopID, toStopID: toStopID, mode: .drive, minutes: 6 + Int((miles * 4.5).rounded()), miles: miles, cost: driveFare(miles: miles))
        }
    }

    /// Waiting for a taxi or rideshare to show up.
    static let pickupMinutes = 5

    /// Taxi or rideshare, whole dollars, never under $10.
    static func driveFare(miles: Double) -> Double {
        max(10, (4 + miles * 3.5).rounded())
    }

    static func streetMiles(from a: Place, to b: Place) -> Double {
        let meters = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        return meters / 1609.34 * 1.25 // street-grid detour factor
    }
}

enum TravelMode: String, Codable, CaseIterable {
    case walk, subway, bus, drive

    /// One subway or bus ride in NYC.
    static let fare = 2.90

    /// The ways you can pick for a trip between stops.
    static let choices: [TravelMode] = [.walk, .subway, .drive]

    /// A mode a newer app version wrote reads as walking instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TravelMode(rawValue: raw) ?? .walk
    }

    var label: String {
        switch self {
        case .walk: "Walk"
        case .subway: "Subway"
        case .bus: "Bus"
        case .drive: "Drive"
        }
    }

    var icon: Lucide {
        switch self {
        case .walk: .footprints
        case .subway: .trainFront
        case .bus: .bus
        case .drive: .car
        }
    }

    var isTransit: Bool { self == .subway || self == .bus }

    /// Route line pattern on the map and timeline: solid walking, dotted transit, dashed driving.
    var dash: [CGFloat] {
        switch self {
        case .walk: []
        case .subway, .bus: [1, 9]
        case .drive: [8, 7]
        }
    }
}

/// Where a leg sits relative to "now", used for route color on the map and timeline.
enum LegState {
    case completed, active, upcoming
}

extension DayPlan {
    var totalCost: Double {
        stopsCost + travelCost + extras.total
    }

    var stopsCost: Double { stops.reduce(0) { $0 + $1.estimatedCost } }

    var travelCost: Double { legs.reduce(0) { $0 + $1.cost } }

    /// Subway and bus fares.
    var faresCost: Double { legs.filter(\.mode.isTransit).reduce(0) { $0 + $1.cost } }

    /// Taxis and rideshares.
    var ridesCost: Double { legs.filter { $0.mode == .drive }.reduce(0) { $0 + $1.cost } }

    /// What's left of the budget; negative when over.
    var remaining: Double { budget - totalCost }

    var walkingMiles: Double {
        legs.filter { $0.mode == .walk }.reduce(0) { $0 + $1.miles }
    }

    var nextStop: PlanStop? { stops.first { $0.status == .upcoming } }

    /// Every stop is done. Empty plans are never "complete".
    var isComplete: Bool { !stops.isEmpty && stops.allSatisfy { $0.status == .done } }

    /// A fresh day with no stops yet.
    static func empty(for date: Date, budget: Double) -> DayPlan {
        DayPlan(date: date, title: "Today", budget: budget, stops: [], legs: [])
    }

    var savedPostCount: Int { stops.compactMap(\.sourcePostID).count }

    func stop(id: UUID) -> PlanStop? { stops.first { $0.id == id } }

    func leg(after stop: PlanStop) -> TravelLeg? { legs.first { $0.fromStopID == stop.id } }

    func state(of leg: TravelLeg) -> LegState {
        let to = stop(id: leg.toStopID)?.status
        if to == .done || to == .now { return .completed }
        if stop(id: leg.fromStopID)?.status == .now { return .active }
        return .upcoming
    }

    /// Plain text for a group chat: where and when to meet, each stop with its time and price,
    /// and what it costs each person including fares. Readable anywhere, no app needed.
    var shareText: String {
        guard let first = stops.first else { return "My Plandit day: nothing planned yet" }
        let meet = [first.place.name, first.place.address].filter { !$0.isEmpty }.joined(separator: ", ")
        let lines = stops.map { stop in
            "\(stop.start.shortTime)  \(stop.place.name) (\(stop.estimatedCost.dollarsText))"
        }
        var including: [String] = []
        if faresCost > 0 { including.append("\(faresCost.dollarsText) in subway fares") }
        if ridesCost > 0 { including.append("\(ridesCost.wholeDollarsText) in rides") }
        let cost = including.isEmpty
            ? "About \(totalCost.wholeDollarsText) per person."
            : "About \(totalCost.wholeDollarsText) per person, including \(including.joined(separator: " and "))."
        let ends = stops.last.map { " Done by \($0.end.shortTime)." } ?? ""
        return ([
            "\(title) · \(date.shortDay)",
            "Meet \(first.start.shortTime) at \(meet)",
            "",
        ] + lines + [
            "",
            cost + ends,
            "Planned with Plandit",
        ]).joined(separator: "\n")
    }
}

extension DayPlan {
    /// Replaces a leg (same id) and moves the stops after it by the change in travel time.
    /// Stops already done or underway never move; a stop never starts before the one ahead of it
    /// has ended and the trip is made; evening spots still start at 8 PM or later.
    mutating func setLeg(_ new: TravelLeg, calendar: Calendar = .current) {
        guard let legIndex = legs.firstIndex(where: { $0.id == new.id }),
              let first = stops.firstIndex(where: { $0.id == new.toStopID }), first > 0 else { return }
        let delta = TimeInterval((new.minutes - legs[legIndex].minutes) * 60)
        legs[legIndex] = new
        shiftStops(from: first, by: delta, calendar: calendar)
    }

    /// The earliest an upcoming stop can start: once the stop before it has ended and the trip there is made.
    func earliestStart(ofStop id: UUID) -> Date? {
        guard let index = stops.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        let previous = stops[index - 1]
        return previous.end.addingTimeInterval(TimeInterval((leg(after: previous)?.minutes ?? 0) * 60))
    }

    /// The user changes when a stop starts and how long they stay. A stop underway keeps its start;
    /// a stop already done doesn't change. With `moveLaterStops`, the stops after it move by the same
    /// amount; without, they only move when they'd overlap.
    mutating func setTime(
        ofStop id: UUID, start requested: Date, durationMinutes: Int,
        moveLaterStops: Bool = true, calendar: Calendar = .current
    ) {
        guard let index = stops.firstIndex(where: { $0.id == id }), stops[index].status != .done else { return }
        let oldEnd = stops[index].end
        if stops[index].status == .upcoming {
            // Their choice wins over the planner's rules (like 8 PM for nightlife), but stops can't overlap.
            stops[index].start = max(requested, earliestStart(ofStop: id) ?? requested)
        }
        stops[index].durationMinutes = max(Self.shortestStay, durationMinutes)
        let delta = moveLaterStops ? stops[index].end.timeIntervalSince(oldEnd) : 0
        shiftStops(from: index + 1, by: delta, calendar: calendar)
    }

    static let shortestStay = 15

    /// Moves upcoming stops from `first` on by `delta`. A stop never starts before the one ahead of it
    /// has ended and the trip is made; evening spots still start at 8 PM or later.
    private mutating func shiftStops(from first: Int, by delta: TimeInterval, calendar: Calendar) {
        guard first > 0 else { return }
        for index in first..<stops.count where stops[index].status == .upcoming {
            let previous = stops[index - 1]
            let travel = TimeInterval((leg(after: previous)?.minutes ?? 0) * 60)
            var start = max(stops[index].start.addingTimeInterval(delta), previous.end.addingTimeInterval(travel))
            if let opens = stops[index].place.category.earliestStartMinutes,
               let evening = calendar.date(byAdding: .minute, value: opens, to: calendar.startOfDay(for: stops[index].start)) {
                start = max(start, evening)
            }
            stops[index].start = start
        }
    }

    /// Stops you'd get to after they close.
    func stopsArrivingAfterClose(calendar: Calendar = .current) -> [PlanStop] {
        stops.filter { stop in
            guard stop.status == .upcoming, let close = stop.place.closingTime(on: date, calendar: calendar) else { return false }
            return stop.start >= close
        }
    }
}
