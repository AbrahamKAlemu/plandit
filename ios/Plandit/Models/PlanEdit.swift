import Foundation

/// One change a member makes to a group plan (mode 3, "edit together").
///
/// Edits name stops by id, never by position, so an edit made on an older copy of the plan can be
/// made again on the server's newer copy (a rebase) without losing what others changed meanwhile:
/// a stop someone else added stays, a stop someone else checked off is never put back. None of
/// them wraps Today's whole-list helpers (`edited(keeping:)`, `reordered`, `setLeg`, the status
/// cascade), which would (MF-A). `apply` says when an edit was already made, or no longer makes
/// sense, instead of quietly doing nothing.
enum PlanEdit: Codable, Equatable {
    /// A new stop, its id fixed here so a rebase never adds it twice. Timed where it lands, as
    /// "Add to today" times it; never before a stop that's done or underway.
    case add(stop: PlanStop, slot: Slot, travel: TravelPreference)
    /// `status` is what the stop was when the member took it out.
    case remove(stopID: UUID, status: StopStatus, travel: TravelPreference)
    /// A stop still ahead goes right after `after`, or first among the stops still ahead when nil.
    case move(stopID: UUID, after: UUID?, travel: TravelPreference)
    /// How to get from one stop to the next. Keyed by the two stops: leg ids change when stops move.
    case setTravel(Trip)
    /// "I'm here", "Done here" or "Not here yet" on one stop.
    case setStatus(StatusChange)
    case setTime(stopID: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool)
    /// Today's catch-up answers, worked out again from the plan and the time when applied.
    case markOverdueDone
    case startRestFromNow

    /// Where an added stop goes. A stop that's gone sends it to the end.
    enum Slot: Codable, Equatable {
        /// First among the stops still ahead.
        case first
        case after(UUID)
        case end
    }

    struct Trip: Codable, Equatable {
        var from: UUID
        var to: UUID
        var mode: TravelMode
        var minutes: Int
        var miles: Double
        var cost: Double
        var detail: String?
    }

    enum StatusAction: String, Codable {
        /// The stop is underway; every stop before it is done.
        case arrive
        /// The stop and every stop before it are done; the next one is underway.
        case complete
        /// Back to planned; the stops before it stay done.
        case leave
    }

    struct StatusChange: Codable, Equatable {
        var stopID: UUID
        var action: StatusAction
        /// The stop's status when the member tapped it.
        var from: StopStatus
        /// Later stops this change puts back (arriving at or leaving a stop that was done), with the
        /// status the member saw. On a newer copy each is put back only if it still has that status.
        var resets: [Reset]
    }

    struct Reset: Codable, Equatable {
        var stopID: UUID
        var status: StopStatus
    }

    enum Outcome: Equatable {
        case applied(DayPlan)
        /// The plan already shows it: the same stop added, the stop already gone, already done.
        case alreadyApplied
        case noLongerApplies(Reason)
    }

    enum Reason: Equatable {
        case stopGone(UUID)
        /// Done, underway or back to planned since: someone else got to it first.
        case stopChanged(UUID)
        case notNextToEachOther
        case planFull
        /// Another stop is already this place.
        case alreadyInPlan(UUID)
    }

    /// The server's limit (`MAX_STOPS`).
    static let maxStops = 20

    // MARK: - Applying

    static func apply(_ edit: PlanEdit, to plan: DayPlan, now: Date, calendar: Calendar) -> Outcome {
        let outcome: Outcome
        switch edit {
        case let .add(stop, slot, travel):
            outcome = add(stop, slot: slot, travel: travel, to: plan, now: now, calendar: calendar)
        case let .remove(stopID, status, travel):
            outcome = remove(stopID, status: status, travel: travel, from: plan, calendar: calendar)
        case let .move(stopID, after, travel):
            outcome = move(stopID, after: after, travel: travel, in: plan, calendar: calendar)
        case let .setTravel(trip):
            outcome = setTravel(trip, in: plan, calendar: calendar)
        case let .setStatus(change):
            outcome = setStatus(change, in: plan)
        case let .setTime(stopID, start, durationMinutes, moveLaterStops):
            guard let stop = plan.stop(id: stopID) else { return .noLongerApplies(.stopGone(stopID)) }
            guard stop.status != .done else { return .noLongerApplies(.stopChanged(stopID)) }
            var result = plan
            result.setTime(ofStop: stopID, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops, calendar: calendar)
            outcome = result == plan ? .alreadyApplied : .applied(result)
        case .markOverdueDone:
            var result = plan
            result.markOverdueDone(now: now)
            outcome = result == plan ? .alreadyApplied : .applied(result)
        case .startRestFromNow:
            var result = plan
            result.startRestFromNow(now: now, calendar: calendar)
            outcome = result == plan ? .alreadyApplied : .applied(result)
        }
        guard case .applied(let result) = outcome else { return outcome }
        return .applied(result.withStableLegIDs(comparedTo: plan))
    }

    private static func add(_ stop: PlanStop, slot: Slot, travel: TravelPreference, to plan: DayPlan, now: Date, calendar: Calendar) -> Outcome {
        if plan.stop(id: stop.id) != nil { return .alreadyApplied }
        if plan.stops.count >= maxStops { return .noLongerApplies(.planFull) }
        if let same = plan.stops.first(where: { $0.place.isSamePlace(as: stop.place) }) {
            return .noLongerApplies(.alreadyInPlan(same.id))
        }
        var position: Int
        switch slot {
        case .first:
            position = plan.firstMovableIndex
        case .after(let anchor):
            position = plan.stops.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? plan.stops.count
        case .end:
            position = plan.stops.count
        }
        position = max(position, plan.firstMovableIndex)
        let insertion = plan.trialInsert(PlanCandidate(stop: stop), at: position, travel: travel, now: now, calendar: calendar, alreadyLate: [])
        return .applied(insertion.plan)
    }

    /// As Today's remove: the trip between the stops either side is estimated, and later stops
    /// move only if they'd overlap.
    private static func remove(_ id: UUID, status: StopStatus, travel: TravelPreference, from plan: DayPlan, calendar: Calendar) -> Outcome {
        guard let index = plan.stops.firstIndex(where: { $0.id == id }) else { return .alreadyApplied }
        let current = plan.stops[index].status
        if current != status && current != .upcoming { return .noLongerApplies(.stopChanged(id)) }
        var result = plan
        result.stops.remove(at: index)
        result.relinkLegs(travel: travel)
        result.shiftStops(from: result.firstMovableIndex, by: 0, calendar: calendar)
        return .applied(result)
    }

    /// The stops between where it was and where it goes are timed again one after another from
    /// when the first of them was due; later stops move only if they'd overlap.
    private static func move(_ id: UUID, after anchor: UUID?, travel: TravelPreference, in plan: DayPlan, calendar: Calendar) -> Outcome {
        guard let from = plan.stops.firstIndex(where: { $0.id == id }) else { return .noLongerApplies(.stopGone(id)) }
        guard plan.stops[from].status == .upcoming else { return .noLongerApplies(.stopChanged(id)) }
        if let anchor, plan.stop(id: anchor) == nil { return .noLongerApplies(.stopGone(anchor)) }
        var stops = plan.stops
        let moving = stops.remove(at: from)
        let firstMovable = stops.lastIndex { $0.status != .upcoming }.map { $0 + 1 } ?? 0
        var to = anchor.flatMap { anchor in stops.firstIndex { $0.id == anchor }.map { $0 + 1 } } ?? firstMovable
        to = max(to, firstMovable)
        if to == from { return .alreadyApplied }
        stops.insert(moving, at: to)
        var result = plan
        result.stops = stops
        result.relinkLegs(travel: travel)
        let low = min(from, to), high = max(from, to)
        result.retimeAhead(from: low, through: high, slot: plan.stops[low].start, calendar: calendar)
        result.shiftStops(from: high + 1, by: 0, calendar: calendar)
        return .applied(result)
    }

    /// As choosing a trip on Today: the stops after it move by the change from the trip the plan
    /// has now (the server's), not the one this phone had.
    private static func setTravel(_ trip: Trip, in plan: DayPlan, calendar: Calendar) -> Outcome {
        guard let fromIndex = plan.stops.firstIndex(where: { $0.id == trip.from }) else { return .noLongerApplies(.stopGone(trip.from)) }
        guard let toIndex = plan.stops.firstIndex(where: { $0.id == trip.to }) else { return .noLongerApplies(.stopGone(trip.to)) }
        guard toIndex == fromIndex + 1 else { return .noLongerApplies(.notNextToEachOther) }
        var result = plan
        let oldMinutes: Int
        var leg: TravelLeg
        if let legIndex = plan.legs.firstIndex(where: { $0.fromStopID == trip.from && $0.toStopID == trip.to }) {
            leg = plan.legs[legIndex]
            oldMinutes = leg.minutes
        } else {
            leg = TravelLeg(fromStopID: trip.from, toStopID: trip.to, mode: trip.mode, minutes: 0, miles: 0)
            oldMinutes = 0
        }
        let old = leg
        leg.mode = trip.mode
        leg.minutes = trip.minutes
        leg.miles = trip.miles
        leg.cost = trip.cost
        leg.detail = trip.detail
        leg.isChosen = true
        if leg == old { return .alreadyApplied }
        if let legIndex = result.legs.firstIndex(where: { $0.id == old.id }), plan.legs.contains(old) {
            result.legs[legIndex] = leg
        } else {
            result.legs.insert(leg, at: min(fromIndex, result.legs.count))
        }
        result.shiftStops(from: toIndex, by: TimeInterval((leg.minutes - oldMinutes) * 60), calendar: calendar)
        return .applied(result)
    }

    /// Stops before it become done; it gets its new status; later stops get what Today would give
    /// them, except that one further along than this member saw is never put back (MF-A).
    private static func setStatus(_ change: StatusChange, in plan: DayPlan) -> Outcome {
        guard let index = plan.stops.firstIndex(where: { $0.id == change.stopID }) else {
            return .noLongerApplies(.stopGone(change.stopID))
        }
        let target = change.action.status
        let current = plan.stops[index].status
        if current == target { return .alreadyApplied }
        if current != change.from { return .noLongerApplies(.stopChanged(change.stopID)) }
        var result = plan
        for earlier in 0..<index where result.stops[earlier].status != .done {
            result.stops[earlier].status = .done
        }
        result.stops[index].status = target
        for later in plan.stops.indices.dropFirst(index + 1) {
            let want = change.action.status(ofLater: later - index)
            let have = plan.stops[later].status
            if want.rank >= have.rank {
                result.stops[later].status = want
            } else if change.resets.contains(Reset(stopID: plan.stops[later].id, status: have)) {
                result.stops[later].status = want
            } else {
                return .noLongerApplies(.stopChanged(plan.stops[later].id))
            }
        }
        return .applied(result)
    }

    // MARK: - On the wire

    /// The server's `edit.kind`: 1 to 16 letters.
    var kind: String {
        switch self {
        case .add: "add"
        case .remove: "remove"
        case .move: "move"
        case .setTravel: "travel"
        case .setStatus(let change): change.action.rawValue
        case .setTime: "time"
        case .markOverdueDone: "markDone"
        case .startRestFromNow: "startFromNow"
        }
    }

    /// The server's `edit.stopIds`: the stops this edit is about, and any other stop whose status
    /// or time it changed, so a 409 can say who changed a stop (MF-C). At most 20.
    func stopIDs(before: DayPlan, after: DayPlan) -> [UUID] {
        var named: [UUID]
        switch self {
        case .add(let stop, _, _): return [stop.id]
        case .remove(let id, _, _), .move(let id, _, _), .setTime(let id, _, _, _): return [id]
        case .setTravel(let trip): return [trip.from, trip.to]
        case .setStatus(let change): named = [change.stopID]
        case .markOverdueDone, .startRestFromNow: named = []
        }
        for stop in after.stops where !named.contains(stop.id) {
            guard let old = before.stop(id: stop.id) else { continue }
            if old.status != stop.status || old.start != stop.start || old.durationMinutes != stop.durationMinutes {
                named.append(stop.id)
            }
        }
        return Array(named.prefix(Self.maxStops))
    }

    /// The id a trip between two stops gets when an edit makes it: the same every time, so the
    /// plan shown and the plan sent match, and applying an edit again gives the same plan.
    static func legID(from: UUID, to: UUID) -> UUID {
        var bytes = withUnsafeBytes(of: from.uuid) { Array($0) } + withUnsafeBytes(of: to.uuid) { Array($0) }
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        for byte in bytes.reversed() {
            second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        bytes = withUnsafeBytes(of: first.bigEndian) { Array($0) } + withUnsafeBytes(of: second.bigEndian) { Array($0) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // version 5 style: derived, not random
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Making edits from what the member sees

    /// "Add to today" in a group plan: the slot Today would pick (`DayPlan.inserting`), named by
    /// the stop before it.
    static func adding(_ candidate: PlanCandidate, to plan: DayPlan, travel: TravelPreference, now: Date, calendar: Calendar) -> PlanEdit {
        let insertion = plan.inserting(candidate, travel: travel, now: now, calendar: calendar)
        let stop = PlanStop(
            id: candidate.id, place: candidate.place, start: insertion.stop.start, durationMinutes: candidate.durationMinutes,
            estimatedCost: candidate.cost, note: candidate.note, sourcePostID: candidate.sourcePostID, status: .upcoming,
            costItems: candidate.costItems, costIsCustom: candidate.costIsCustom
        )
        let slot: Slot = insertion.position == 0 ? .first : .after(plan.stops[insertion.position - 1].id)
        return .add(stop: stop, slot: slot, travel: travel)
    }

    static func removing(_ stopID: UUID, in plan: DayPlan, travel: TravelPreference) -> PlanEdit? {
        plan.stop(id: stopID).map { .remove(stopID: stopID, status: $0.status, travel: travel) }
    }

    /// The Edit plan sheet's answer (the stops still ahead, in order, minus any taken out) as
    /// removes and moves, each naming the stop it goes after. Ids that aren't all stops still
    /// ahead give no edits, as `edited(keeping:)` changes nothing.
    static func reordering(_ ids: [UUID], in plan: DayPlan, travel: TravelPreference) -> [PlanEdit] {
        let movable = plan.stops[plan.firstMovableIndex...].map(\.id)
        guard Set(ids).count == ids.count, Set(ids).isSubset(of: Set(movable)) else { return [] }
        var edits: [PlanEdit] = []
        var current = movable
        for id in movable where !ids.contains(id) {
            edits.append(.remove(stopID: id, status: .upcoming, travel: travel))
            current.removeAll { $0 == id }
        }
        for (index, id) in ids.enumerated() where current[index] != id {
            edits.append(.move(stopID: id, after: index == 0 ? nil : ids[index - 1], travel: travel))
            current.removeAll { $0 == id }
            current.insert(id, at: index)
        }
        return edits
    }

    /// Today's "I'm here", "Done here" and "Not here yet", recording which later stops it puts back.
    static func status(_ action: StatusAction, stopID: UUID, in plan: DayPlan) -> PlanEdit? {
        guard let index = plan.stops.firstIndex(where: { $0.id == stopID }) else { return nil }
        let resets = plan.stops.indices.dropFirst(index + 1).compactMap { later -> Reset? in
            let have = plan.stops[later].status
            return action.status(ofLater: later - index).rank < have.rank ? Reset(stopID: plan.stops[later].id, status: have) : nil
        }
        return .setStatus(StatusChange(stopID: stopID, action: action, from: plan.stops[index].status, resets: resets))
    }

    /// Choosing how to make one trip (a `TravelOption`'s leg).
    static func travel(_ leg: TravelLeg) -> PlanEdit {
        .setTravel(Trip(from: leg.fromStopID, to: leg.toStopID, mode: leg.mode, minutes: leg.minutes, miles: leg.miles, cost: leg.cost, detail: leg.detail))
    }
}

private extension PlanEdit.StatusAction {
    var status: StopStatus {
        switch self {
        case .arrive: .now
        case .complete: .done
        case .leave: .upcoming
        }
    }

    /// What Today gives the stop `offset` places after the one tapped.
    func status(ofLater offset: Int) -> StopStatus {
        self == .complete && offset == 1 ? .now : .upcoming
    }
}

private extension StopStatus {
    /// How far along: planned, underway, done.
    var rank: Int {
        switch self {
        case .upcoming: 0
        case .now: 1
        case .done: 2
        }
    }
}

private extension Place {
    /// The same place added from two members' saves: same name, within about 50 m.
    func isSamePlace(as other: Place) -> Bool {
        if id == other.id { return true }
        return name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(other.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
            && abs(latitude - other.latitude) < 0.0005 && abs(longitude - other.longitude) < 0.0005
    }
}

private extension DayPlan {
    /// Trips an edit added get an id from their two stops (`PlanEdit.legID`).
    func withStableLegIDs(comparedTo before: DayPlan) -> DayPlan {
        let known = Set(before.legs.map(\.id))
        var plan = self
        for index in plan.legs.indices where !known.contains(plan.legs[index].id) {
            plan.legs[index].id = PlanEdit.legID(from: plan.legs[index].fromStopID, to: plan.legs[index].toStopID)
        }
        return plan
    }
}
