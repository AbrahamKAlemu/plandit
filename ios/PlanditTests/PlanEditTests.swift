import XCTest
@testable import Plandit

/// Test plan 2.1: each `PlanEdit` made on one copy of a group plan and applied to the server's
/// newer copy, where (a) its stop was removed, (b) moved, (c) changed, (d) another stop was added,
/// (e) another removed, (f) the edit was already made, or (g) nothing else changed.
/// Sample day, all still ahead: Pastry 9:30 → Met → High Line → Tacos → Washington Sq.
@MainActor final class PlanEditTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: hour, minute: minute))!
    }

    /// Before the day starts, so "now" never pushes anything.
    private var morning: Date { at(8) }

    private func day() -> DayPlan {
        let places: [(Place, Int)] = [
            (SampleData.hungarianPastry, 45), (SampleData.met, 90), (SampleData.highLine, 60),
            (SampleData.losTacos, 45), (SampleData.washingtonSquare, 60),
        ]
        var stops: [PlanStop] = []
        var legs: [TravelLeg] = []
        for (place, minutes) in places {
            var stop = PlanStop(place: place, start: at(9, 30), durationMinutes: minutes, estimatedCost: 5, status: .upcoming)
            if let previous = stops.last {
                let leg = TravelLeg.estimate(from: previous, to: stop, travel: .walkAndTransit)
                legs.append(leg)
                stop.start = previous.end.addingTimeInterval(TimeInterval(leg.minutes * 60))
            }
            stops.append(stop)
        }
        return DayPlan(date: at(9), title: "Uptown to the Village", budget: 60, stops: stops, legs: legs)
    }

    private func spot(_ name: String, _ latitude: Double, _ longitude: Double) -> Place {
        Place(name: name, category: .food, neighborhood: "Test", address: "\(name) St", latitude: latitude, longitude: longitude)
    }

    private func outcome(_ edit: PlanEdit?, on plan: DayPlan, now: Date? = nil) -> PlanEdit.Outcome? {
        edit.map { PlanEdit.apply($0, to: plan, now: now ?? morning, calendar: calendar) }
    }

    private func applied(_ edit: PlanEdit?, to plan: DayPlan, now: Date? = nil, file: StaticString = #filePath, line: UInt = #line) -> DayPlan {
        guard let edit else {
            XCTFail("no edit", file: file, line: line)
            return plan
        }
        switch PlanEdit.apply(edit, to: plan, now: now ?? morning, calendar: calendar) {
        case .applied(let result): return result
        case let other:
            XCTFail("expected applied, got \(other)", file: file, line: line)
            return plan
        }
    }

    private func applying(_ edits: [PlanEdit], to plan: DayPlan, file: StaticString = #filePath, line: UInt = #line) -> DayPlan {
        edits.reduce(plan) { applied($1, to: $0, file: file, line: line) }
    }

    /// Another member's edit, made on their copy.
    private func mayaAdds(_ place: Place, after index: Int?, to plan: DayPlan) -> (plan: DayPlan, stopID: UUID) {
        let stop = PlanStop(place: place, start: morning, durationMinutes: 30, estimatedCost: 4, status: .upcoming)
        let slot: PlanEdit.Slot = index.map { .after(plan.stops[$0].id) } ?? .end
        return (applied(.add(stop: stop, slot: slot, travel: .walkAndTransit), to: plan), stop.id)
    }

    private func ids(_ plan: DayPlan) -> [UUID] { plan.stops.map(\.id) }

    private func setStatuses(_ plan: inout DayPlan, _ statuses: [StopStatus]) {
        for (index, status) in statuses.enumerated() { plan.stops[index].status = status }
    }

    /// Every trip joins two stops that are next to each other, and nothing ahead overlaps.
    private func assertConsistent(_ plan: DayPlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.legs.count, max(0, plan.stops.count - 1), file: file, line: line)
        XCTAssertEqual(Set(ids(plan)).count, plan.stops.count, "duplicate stop", file: file, line: line)
        for (leg, (from, to)) in zip(plan.legs, zip(plan.stops, plan.stops.dropFirst())) {
            XCTAssertEqual(leg.fromStopID, from.id, file: file, line: line)
            XCTAssertEqual(leg.toStopID, to.id, file: file, line: line)
            if to.status == .upcoming {
                XCTAssertGreaterThanOrEqual(to.start, from.end.addingTimeInterval(TimeInterval(leg.minutes * 60)), "\(to.place.name) overlaps", file: file, line: line)
            }
        }
    }

    // MARK: - add

    /// 2.1 add (d).
    func testAddKeepsAStopAnotherMemberAddedMeanwhile() {
        let base = day()
        let mine = PlanEdit.adding(PlanCandidate(place: SampleData.levain, cost: 6), to: base, travel: .walkAndTransit, now: morning, calendar: calendar)
        let local = applied(mine, to: base)
        let maya = mayaAdds(SampleData.littleIsland, after: nil, to: base)

        let rebased = applied(mine, to: maya.plan)

        guard case .add(let stop, _, _) = mine else { return XCTFail("not an add") }
        XCTAssertEqual(rebased.stops.count, base.stops.count + 2)
        XCTAssertTrue(ids(rebased).contains(maya.stopID), "Maya's stop is kept")
        XCTAssertTrue(Set(ids(base)).isSubset(of: Set(ids(rebased))))
        // Same id, same neighbor as on this phone.
        let index = rebased.stops.firstIndex { $0.id == stop.id }!
        let localIndex = local.stops.firstIndex { $0.id == stop.id }!
        XCTAssertEqual(rebased.stops[index - 1].id, local.stops[localIndex - 1].id)
        assertConsistent(rebased)
    }

    /// 2.1 add (e).
    func testAddWhenAnotherStopWasRemovedKeepsTheRest() {
        let base = day()
        let mine = PlanEdit.adding(PlanCandidate(place: SampleData.levain, cost: 6), to: base, travel: .walkAndTransit, now: morning, calendar: calendar)
        let server = applied(.remove(stopID: base.stops[4].id, status: .upcoming, travel: .walkAndTransit), to: base)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(rebased.stops.count, server.stops.count + 1)
        XCTAssertTrue(Set(ids(server)).isSubset(of: Set(ids(rebased))))
        XCTAssertFalse(ids(rebased).contains(base.stops[4].id))
        assertConsistent(rebased)
    }

    /// 2.1 add (f): the stop's id is already there, so no second copy.
    func testAddAlreadyMadeIsNotAddedTwice() {
        let base = day()
        let mine = PlanEdit.adding(PlanCandidate(place: SampleData.levain, cost: 6), to: base, travel: .walkAndTransit, now: morning, calendar: calendar)
        let server = applied(mine, to: base)

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
    }

    /// 2.1 add: a plan already at 20 stops.
    func testAddToAFullPlanNoLongerApplies() {
        var full = day()
        for index in 0..<15 {
            full.stops.append(PlanStop(place: spot("Spot \(index)", 40.70 + Double(index) / 1000, -73.99), start: at(20), durationMinutes: 15, estimatedCost: 0, status: .upcoming))
        }
        full.relinkLegs(travel: .walkAndTransit)
        XCTAssertEqual(full.stops.count, 20)
        let mine = PlanEdit.add(stop: PlanStop(place: SampleData.levain, start: morning, durationMinutes: 30, estimatedCost: 6, status: .upcoming),
                                slot: .end, travel: .walkAndTransit)

        XCTAssertEqual(outcome(mine, on: full), .noLongerApplies(.planFull))
    }

    /// 2.1 add: every stop done meanwhile, so it goes at the end.
    func testAddAfterEveryStopIsDoneGoesAtTheEnd() {
        let base = day()
        let mine = PlanEdit.add(stop: PlanStop(place: SampleData.levain, start: morning, durationMinutes: 30, estimatedCost: 6, status: .upcoming),
                                slot: .after(base.stops[1].id), travel: .walkAndTransit)
        var server = base
        setStatuses(&server, [.done, .done, .done, .done, .done])

        let rebased = applied(mine, to: server)

        XCTAssertEqual(rebased.stops.last?.place.name, SampleData.levain.name)
        XCTAssertEqual(Array(ids(rebased).prefix(5)), ids(server))
        assertConsistent(rebased)
    }

    /// 2.1 add (a): the stop it was going after is gone, so it goes at the end.
    func testAddAfterAStopSomeoneRemovedGoesAtTheEnd() {
        let base = day()
        let mine = PlanEdit.add(stop: PlanStop(place: SampleData.levain, start: morning, durationMinutes: 30, estimatedCost: 6, status: .upcoming),
                                slot: .after(base.stops[1].id), travel: .walkAndTransit)
        let server = applied(.remove(stopID: base.stops[1].id, status: .upcoming, travel: .walkAndTransit), to: base)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(rebased.stops.last?.place.name, SampleData.levain.name)
        XCTAssertEqual(Array(ids(rebased).prefix(4)), ids(server))
    }

    /// 2.1 add: the id is fixed in the edit, so it stays the same through a rebase.
    func testAddKeepsItsStopIDThroughARebase() {
        let base = day()
        let candidate = PlanCandidate(place: SampleData.levain, cost: 6)
        let mine = PlanEdit.adding(candidate, to: base, travel: .walkAndTransit, now: morning, calendar: calendar)
        let server = mayaAdds(SampleData.littleIsland, after: 0, to: base).plan

        let rebased = applied(mine, to: server)

        XCTAssertNotNil(rebased.stop(id: candidate.id))
        XCTAssertEqual(applied(mine, to: server), rebased, "the same plan every time, trips included")
    }

    /// SW-5: two members adding the same place.
    func testAddOfAPlaceAnotherMemberAlreadyAddedNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.adding(PlanCandidate(place: SampleData.levain, cost: 6), to: base, travel: .walkAndTransit, now: morning, calendar: calendar)
        let maya = mayaAdds(SampleData.levain, after: 1, to: base)

        XCTAssertEqual(outcome(mine, on: maya.plan), .noLongerApplies(.alreadyInPlan(maya.stopID)))
    }

    /// 2.1 add (g): the same as Today's "Add to today".
    func testAddOnAnUnchangedPlanMatchesTheLocalInsertion() {
        let base = day()
        let candidate = PlanCandidate(place: SampleData.levain, cost: 6)
        let insertion = base.inserting(candidate, travel: .walkAndTransit, now: morning, calendar: calendar)
        let mine = PlanEdit.adding(candidate, to: base, travel: .walkAndTransit, now: morning, calendar: calendar)

        let result = applied(mine, to: base)

        XCTAssertEqual(result.stops, insertion.plan.stops)
        assertConsistent(result)
    }

    // MARK: - remove

    /// 2.1 remove (d): regression for `edited(keeping:)`, which drops a stop added since.
    func testRemoveKeepsAStopAnotherMemberAdded() {
        let base = day()
        let mine = PlanEdit.removing(base.stops[2].id, in: base, travel: .walkAndTransit)
        let maya = mayaAdds(SampleData.littleIsland, after: 3, to: base)

        let rebased = applied(mine, to: maya.plan)

        XCTAssertTrue(ids(rebased).contains(maya.stopID))
        XCTAssertFalse(ids(rebased).contains(base.stops[2].id))
        XCTAssertEqual(ids(rebased), ids(maya.plan).filter { $0 != base.stops[2].id })
        assertConsistent(rebased)
    }

    /// 2.1 remove (a), (f): someone removed it first; what this member wanted is done.
    func testRemoveOfAStopAlreadyRemovedIsAlreadyApplied() {
        let base = day()
        let mine = PlanEdit.removing(base.stops[2].id, in: base, travel: .walkAndTransit)
        let server = applied(mine, to: base)

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
    }

    /// 2.1 remove (b).
    func testRemoveOfAStopThatMovedRemovesItFromItsNewPlace() {
        let base = day()
        let mine = PlanEdit.removing(base.stops[1].id, in: base, travel: .walkAndTransit)
        let server = applied(.move(stopID: base.stops[1].id, after: base.stops[4].id, travel: .walkAndTransit), to: base)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(ids(rebased), ids(server).filter { $0 != base.stops[1].id })
        assertConsistent(rebased)
    }

    /// 2.1 remove (c): someone got there meanwhile.
    func testRemoveOfAStopSomeoneArrivedAtNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.removing(base.stops[2].id, in: base, travel: .walkAndTransit)
        let server = applied(PlanEdit.status(.arrive, stopID: base.stops[2].id, in: base), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopChanged(base.stops[2].id)))
    }

    /// 2.1 remove (g): the same as Today's remove.
    func testRemoveOnAnUnchangedPlanMatchesTodaysRemove() {
        let base = day()
        var expected = base
        expected.stops.remove(at: 2)
        expected.relinkLegs(travel: .walkAndTransit)
        expected.shiftStops(from: expected.firstMovableIndex, by: 0, calendar: calendar)

        let result = applied(PlanEdit.removing(base.stops[2].id, in: base, travel: .walkAndTransit), to: base)

        XCTAssertEqual(result.stops, expected.stops)
        assertConsistent(result)
    }

    // MARK: - move

    /// 2.1 move (a).
    func testMoveOfARemovedStopNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[2].id, after: base.stops[4].id, travel: .walkAndTransit)
        let server = applied(.remove(stopID: base.stops[2].id, status: .upcoming, travel: .walkAndTransit), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopGone(base.stops[2].id)))
    }

    /// 2.1 move (c): done or underway stops never move.
    func testMoveOfAStopUnderwayOrDoneNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[1].id, after: base.stops[3].id, travel: .walkAndTransit)
        var underway = base
        setStatuses(&underway, [.done, .now])
        var done = base
        setStatuses(&done, [.done, .done, .now])

        XCTAssertEqual(outcome(mine, on: underway), .noLongerApplies(.stopChanged(base.stops[1].id)))
        XCTAssertEqual(outcome(mine, on: done), .noLongerApplies(.stopChanged(base.stops[1].id)))
    }

    /// 2.1 move (d): it goes after its anchor, and the other member's stop stays.
    func testMoveKeepsAStopAnotherMemberAddedAndGoesAfterItsAnchor() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[1].id, after: base.stops[3].id, travel: .walkAndTransit)
        let maya = mayaAdds(SampleData.littleIsland, after: 3, to: base)

        let rebased = applied(mine, to: maya.plan)

        let order = ids(rebased)
        XCTAssertEqual(order.count, maya.plan.stops.count)
        XCTAssertTrue(order.contains(maya.stopID))
        XCTAssertEqual(order[order.firstIndex(of: base.stops[3].id)! + 1], base.stops[1].id)
        assertConsistent(rebased)
    }

    /// 2.1 move (e).
    func testMoveWhenAnotherStopWasRemoved() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[1].id, after: base.stops[3].id, travel: .walkAndTransit)
        let server = applied(.remove(stopID: base.stops[4].id, status: .upcoming, travel: .walkAndTransit), to: base)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(ids(rebased), [base.stops[0].id, base.stops[2].id, base.stops[3].id, base.stops[1].id])
        assertConsistent(rebased)
    }

    /// 2.1 move: the stop it was going after is gone. Decided: no guessing where it goes.
    func testMoveAfterAnAnchorSomeoneRemovedNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[1].id, after: base.stops[3].id, travel: .walkAndTransit)
        let server = applied(.remove(stopID: base.stops[3].id, status: .upcoming, travel: .walkAndTransit), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopGone(base.stops[3].id)))
    }

    /// 2.1 move (f).
    func testMoveAlreadyMadeIsAlreadyApplied() {
        let base = day()
        let mine = PlanEdit.move(stopID: base.stops[1].id, after: base.stops[3].id, travel: .walkAndTransit)
        let server = applied(mine, to: base)

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
    }

    /// 2.1 move regression: Today's `reordered` returns the plan unchanged when the stop list
    /// differs. A whole-list reorder against a plan with one more stop must neither do nothing nor
    /// drop that stop.
    func testReorderAgainstAPlanWithOneMoreStopIsNeitherIgnoredNorLossy() {
        let base = day()
        let order = [base.stops[0].id, base.stops[3].id, base.stops[1].id, base.stops[4].id, base.stops[2].id]
        let edits = PlanEdit.reordering(order, in: base, travel: .walkAndTransit)
        XCTAssertFalse(edits.isEmpty)
        let maya = mayaAdds(SampleData.littleIsland, after: nil, to: base)

        let rebased = applying(edits, to: maya.plan)

        XCTAssertEqual(ids(rebased).filter { $0 != maya.stopID }, order)
        XCTAssertTrue(ids(rebased).contains(maya.stopID))
        assertConsistent(rebased)
    }

    /// 2.1 move (g): the same order as Today's reorder.
    func testReorderOnAnUnchangedPlanMatchesTodaysOrder() {
        let base = day()
        let order = [base.stops[2].id, base.stops[0].id, base.stops[4].id, base.stops[1].id, base.stops[3].id]

        let result = applying(PlanEdit.reordering(order, in: base, travel: .walkAndTransit), to: base)

        XCTAssertEqual(ids(result), ids(base.reordered(order, travel: .walkAndTransit, calendar: calendar)))
        assertConsistent(result)
    }

    /// The Edit plan sheet with a stop left out: removed, the rest in order.
    func testReorderWithAStopLeftOutRemovesIt() {
        let base = day()
        let order = [base.stops[0].id, base.stops[3].id, base.stops[1].id, base.stops[4].id]

        let edits = PlanEdit.reordering(order, in: base, travel: .walkAndTransit)
        let result = applying(edits, to: base)

        XCTAssertTrue(edits.contains { if case .remove(base.stops[2].id, _, _) = $0 { true } else { false } })
        XCTAssertEqual(ids(result), order)
    }

    // MARK: - setTravel

    /// 2.1 setTravel: keyed by the stop pair; leg ids change when stops move.
    func testTravelIsKeyedByTheTwoStopsNotTheLegID() {
        let base = day()
        let mine = PlanEdit.travel(TravelLeg.estimate(.drive, miles: 2, fromStopID: base.stops[1].id, toStopID: base.stops[2].id))
        var server = base
        for index in server.legs.indices { server.legs[index].id = UUID() }

        let rebased = applied(mine, to: server)

        let leg = rebased.legs.first { $0.fromStopID == base.stops[1].id && $0.toStopID == base.stops[2].id }!
        XCTAssertEqual(leg.mode, .drive)
        XCTAssertTrue(leg.isChosen)
        XCTAssertEqual(leg.id, server.legs[1].id, "the server's leg keeps its id")
        assertConsistent(rebased)
    }

    /// 2.1 setTravel: still next to each other after other changes; later stops move by the
    /// difference from the server's trip, not this phone's.
    func testTravelShiftsLaterStopsByTheServersLegMinutes() {
        let base = day()
        var bus = base.legs[1]
        bus.mode = .bus
        bus.minutes += 10
        let server = applied(PlanEdit.travel(bus), to: base)
        var drive = base.legs[1]
        drive.mode = .drive
        drive.minutes += 25
        let mine = PlanEdit.travel(drive)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(rebased.legs[1].minutes, drive.minutes)
        XCTAssertEqual(rebased.stops[2].start, server.stops[2].start.addingTimeInterval(15 * 60))
        assertConsistent(rebased)
    }

    /// 2.1 setTravel: the two stops aren't next to each other any more.
    func testTravelBetweenStopsNoLongerNextToEachOtherNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.travel(TravelLeg.estimate(.drive, miles: 2, fromStopID: base.stops[1].id, toStopID: base.stops[2].id))
        let server = mayaAdds(SampleData.levain, after: 1, to: base).plan

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.notNextToEachOther))
    }

    /// 2.1 setTravel (a).
    func testTravelToARemovedStopNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.travel(TravelLeg.estimate(.drive, miles: 2, fromStopID: base.stops[1].id, toStopID: base.stops[2].id))
        let server = applied(.remove(stopID: base.stops[2].id, status: .upcoming, travel: .walkAndTransit), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopGone(base.stops[2].id)))
    }

    /// 2.1 setTravel (f).
    func testTravelAlreadyChosenIsAlreadyApplied() {
        let base = day()
        let mine = PlanEdit.travel(TravelLeg.estimate(.drive, miles: 2, fromStopID: base.stops[1].id, toStopID: base.stops[2].id))
        let server = applied(mine, to: base)

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
    }

    // MARK: - setStatus

    /// 2.1 setStatus regression: Today's `setStatuses` sets every stop by position. Completing the
    /// first stop against a plan where someone completed the third must not put the second or the
    /// third back to planned.
    func testTwoCheckOffsAtOnceNeverPutAStopBack() {
        var base = day()
        setStatuses(&base, [.now])
        let mine = PlanEdit.status(.complete, stopID: base.stops[0].id, in: base)
        let maya = PlanEdit.status(.complete, stopID: base.stops[2].id, in: base)
        let server = applied(maya, to: base)

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
        // The other order: mine landed first, then Maya's.
        let mineFirst = applied(maya, to: applied(mine, to: base))
        XCTAssertEqual(mineFirst.stops.map(\.status), [.done, .done, .done, .now, .upcoming])
    }

    /// 2.1 setStatus (a).
    func testArriveAtAStopSomeoneRemovedNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.status(.arrive, stopID: base.stops[2].id, in: base)
        let server = applied(.remove(stopID: base.stops[2].id, status: .upcoming, travel: .walkAndTransit), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopGone(base.stops[2].id)))
    }

    /// 2.1 setStatus (f).
    func testCompleteOfAStopAlreadyDoneIsAlreadyApplied() {
        var base = day()
        setStatuses(&base, [.now])
        let mine = PlanEdit.status(.complete, stopID: base.stops[0].id, in: base)
        var server = base
        setStatuses(&server, [.done, .now])

        XCTAssertEqual(outcome(mine, on: server), .alreadyApplied)
    }

    /// 2.1 setStatus: "isn't done" puts the stop after it back only while it's as this member saw it.
    func testArriveNeverMovesALaterStopSomeoneChangedBack() {
        var base = day()
        setStatuses(&base, [.done, .now])
        let mine = PlanEdit.status(.arrive, stopID: base.stops[0].id, in: base)
        let server = applied(PlanEdit.status(.complete, stopID: base.stops[1].id, in: base), to: base)

        XCTAssertEqual(applied(mine, to: base).stops.map(\.status), [.now, .upcoming, .upcoming, .upcoming, .upcoming])
        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopChanged(base.stops[1].id)))
    }

    /// 2.1 setStatus (c).
    func testLeaveOfAStopSomeoneCompletedNoLongerApplies() {
        var base = day()
        setStatuses(&base, [.done, .now])
        let mine = PlanEdit.status(.leave, stopID: base.stops[1].id, in: base)
        let server = applied(PlanEdit.status(.complete, stopID: base.stops[1].id, in: base), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopChanged(base.stops[1].id)))
    }

    /// 2.1 setStatus (d): by id; earlier stops become done, the next one (whoever added it) is now.
    func testCompleteOnAPlanWithAnExtraStopAppliesByID() {
        var base = day()
        setStatuses(&base, [.done, .now])
        let mine = PlanEdit.status(.complete, stopID: base.stops[1].id, in: base)
        let maya = mayaAdds(SampleData.levain, after: 1, to: base)

        let rebased = applied(mine, to: maya.plan)

        XCTAssertEqual(rebased.stops.map(\.status), [.done, .done, .now, .upcoming, .upcoming, .upcoming])
        XCTAssertEqual(rebased.stops[2].id, maya.stopID)
    }

    // MARK: - setTime

    /// 2.1 setTime (a).
    func testTimeOfARemovedStopNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.setTime(stopID: base.stops[2].id, start: at(14), durationMinutes: 60, moveLaterStops: true)
        let server = applied(.remove(stopID: base.stops[2].id, status: .upcoming, travel: .walkAndTransit), to: base)

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopGone(base.stops[2].id)))
    }

    /// 2.1 setTime (c): done meanwhile. Not a silent no-op like `DayPlan.setTime`.
    func testTimeOfAStopNowDoneNoLongerApplies() {
        let base = day()
        let mine = PlanEdit.setTime(stopID: base.stops[1].id, start: at(12), durationMinutes: 60, moveLaterStops: true)
        var server = base
        setStatuses(&server, [.done, .done, .now])

        XCTAssertEqual(outcome(mine, on: server), .noLongerApplies(.stopChanged(base.stops[1].id)))
    }

    /// 2.1 setTime (b): applies where the stop is now; the stops after it there move.
    func testTimeOfAStopThatMovedAppliesThereAndShiftsTheStopsAfterIt() {
        let base = day()
        let moved = base.stops[1].id
        let server = applied(.move(stopID: moved, after: base.stops[3].id, travel: .walkAndTransit), to: base)
        let old = server.stop(id: moved)!
        let mine = PlanEdit.setTime(stopID: moved, start: old.start.addingTimeInterval(30 * 60), durationMinutes: old.durationMinutes, moveLaterStops: true)

        let rebased = applied(mine, to: server)

        XCTAssertEqual(rebased.stop(id: moved)?.start, old.start.addingTimeInterval(30 * 60))
        XCTAssertEqual(rebased.stops[4].start, server.stops[4].start.addingTimeInterval(30 * 60))
        XCTAssertEqual(Array(rebased.stops.prefix(3)), Array(server.stops.prefix(3)))
    }

    /// 2.1 setTime (d).
    func testTimeKeepsAStopAnotherMemberAdded() {
        let base = day()
        let mine = PlanEdit.setTime(stopID: base.stops[3].id, start: base.stops[3].start.addingTimeInterval(20 * 60), durationMinutes: 75, moveLaterStops: true)
        let maya = mayaAdds(SampleData.levain, after: 0, to: base)

        let rebased = applied(mine, to: maya.plan)

        XCTAssertEqual(ids(rebased), ids(maya.plan))
        assertConsistent(rebased)
    }

    /// 2.1 setTime (f).
    func testTimeAlreadySetIsAlreadyApplied() {
        let base = day()
        let mine = PlanEdit.setTime(stopID: base.stops[3].id, start: base.stops[3].start.addingTimeInterval(20 * 60), durationMinutes: 45, moveLaterStops: true)

        XCTAssertEqual(outcome(mine, on: applied(mine, to: base)), .alreadyApplied)
    }

    // MARK: - Catching up

    /// 2.1 catch-up (N-20): two members' "Start from now" move the day once.
    func testTwoMembersStartingFromNowShiftTheDayOnce() {
        var base = day()
        setStatuses(&base, [.now])
        let now = at(11, 0)
        let server = applied(.startRestFromNow, to: base, now: now)

        XCTAssertNotEqual(server, base)
        XCTAssertEqual(outcome(.startRestFromNow, on: server, now: now), .alreadyApplied)
    }

    /// 2.1 catch-up: "Mark them done" twice is once; another member's new stop stays.
    func testMarkOverdueDoneTwiceIsOnceAndKeepsAnAddedStop() {
        let base = day()
        let now = at(13, 0)
        let maya = mayaAdds(SampleData.littleIsland, after: nil, to: base)
        let server = applied(.markOverdueDone, to: maya.plan, now: now)

        XCTAssertTrue(ids(server).contains(maya.stopID))
        XCTAssertEqual(server.stops[0].status, .done)
        XCTAssertEqual(outcome(.markOverdueDone, on: server, now: now), .alreadyApplied)
    }

    // MARK: - On the wire

    /// The server takes `kind` as 1 to 16 letters (`_EDIT_KIND`).
    func testEveryKindIsOneToSixteenLettersAndDistinct() {
        let id = UUID()
        let stop = PlanStop(place: SampleData.levain, start: morning, durationMinutes: 30, estimatedCost: 6, status: .upcoming)
        let edits: [PlanEdit] = [
            .add(stop: stop, slot: .end, travel: .walkOnly),
            .remove(stopID: id, status: .upcoming, travel: .walkOnly),
            .move(stopID: id, after: nil, travel: .walkOnly),
            .setTravel(.init(from: id, to: UUID(), mode: .walk, minutes: 5, miles: 0.2, cost: 0, detail: nil)),
            .setStatus(.init(stopID: id, action: .arrive, from: .upcoming, resets: [])),
            .setStatus(.init(stopID: id, action: .complete, from: .now, resets: [])),
            .setStatus(.init(stopID: id, action: .leave, from: .now, resets: [])),
            .setTime(stopID: id, start: morning, durationMinutes: 30, moveLaterStops: true),
            .markOverdueDone,
            .startRestFromNow,
        ]
        let kinds = edits.map(\.kind)
        XCTAssertEqual(Set(kinds).count, edits.count)
        for kind in kinds {
            XCTAssertNotNil(kind.wholeMatch(of: /[A-Za-z]{1,16}/), kind)
        }
    }

    /// Pending edits are written to the group cache and read back after a relaunch.
    func testEditsSurviveEncoding() throws {
        let base = day()
        let edits: [PlanEdit] = [
            PlanEdit.adding(PlanCandidate(place: SampleData.levain, cost: 6), to: base, travel: .walkOnly, now: morning, calendar: calendar),
            PlanEdit.removing(base.stops[1].id, in: base, travel: .walkAndTransit)!,
            .move(stopID: base.stops[1].id, after: nil, travel: .walkAndTransit),
            PlanEdit.travel(base.legs[0]),
            PlanEdit.status(.arrive, stopID: base.stops[2].id, in: base)!,
            .setTime(stopID: base.stops[1].id, start: at(12), durationMinutes: 50, moveLaterStops: false),
            .markOverdueDone,
            .startRestFromNow,
        ]
        let data = try JSONEncoder().encode(edits)
        XCTAssertEqual(try JSONDecoder().decode([PlanEdit].self, from: data), edits)
    }

    /// MF-C: the 409 names who touched a stop, so a check-off names every stop it changed.
    func testStopIDsNameEveryStopAnEditChanged() {
        let base = day()
        let edit = PlanEdit.status(.complete, stopID: base.stops[2].id, in: base)!
        let after = applied(edit, to: base)

        XCTAssertEqual(Set(edit.stopIDs(before: base, after: after)), Set(ids(base).prefix(4)))
        let remove = PlanEdit.removing(base.stops[1].id, in: base, travel: .walkAndTransit)!
        XCTAssertEqual(remove.stopIDs(before: base, after: applied(remove, to: base)), [base.stops[1].id])
        let trip = PlanEdit.travel(base.legs[2])
        XCTAssertEqual(trip.stopIDs(before: base, after: base), [base.stops[2].id, base.stops[3].id])
    }

    /// New trips get an id from their two stops, so the plan shown and the plan sent match.
    func testNewTripsGetTheSameIDEveryTime() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(PlanEdit.legID(from: a, to: b), PlanEdit.legID(from: a, to: b))
        XCTAssertNotEqual(PlanEdit.legID(from: a, to: b), PlanEdit.legID(from: b, to: a))
        let base = day()
        let remove = PlanEdit.removing(base.stops[2].id, in: base, travel: .walkAndTransit)
        XCTAssertEqual(applied(remove, to: base), applied(remove, to: base))
    }

    /// N-18: a full 20-stop plan fits well under the server's 64 KB limit.
    func testAFullPlanFitsTheSizeLimit() throws {
        var full = day()
        for index in 0..<15 {
            var place = spot("A place with quite a long name number \(index)", 40.70 + Double(index) / 1000, -73.99)
            place.hours = "Open until 11 PM"
            full.stops.append(PlanStop(place: place, start: at(20), durationMinutes: 15, estimatedCost: 12.5,
                                       note: "Added from your saved TikTok post.", sourcePostID: UUID(), status: .upcoming,
                                       costItems: [CostItem(name: "Ticket", amount: 12.5)]))
        }
        full.relinkLegs(travel: .walkAndTransit)

        XCTAssertLessThan(try JSONEncoder().encode(full).count, 56 * 1024)
    }
}
