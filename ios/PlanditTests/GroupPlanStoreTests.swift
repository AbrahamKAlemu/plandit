import CoreLocation
import Observation
import XCTest
@testable import Plandit

/// Test plan 2.2 to 2.7 at the store: the edit queue and its rebase loop (RB), polling (POL),
/// a removed member or ended group (REM), rollover (RO), offline and relaunch (OFF), and the
/// Today switch's store-level rules (SW-1 to SW-3). Against `FakeGroupPlanServer`, with a clock
/// the test moves by hand. Maya organizes; Jordan and you (Sofia) are in her group. The sample day
/// is 2026-11-20, all still ahead at 8 AM: Pastry 9:30 → Met → High Line → Tacos → Washington Sq.
@MainActor final class GroupPlanStoreTests: XCTestCase {
    private struct NoRoutes: RouteProviding {
        func route(_ mode: TravelMode, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> RouteInfo? { nil }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private var directory: URL!
    private var server: FakeGroupPlanServer!
    private var clock: ManualSleeper!
    private var now: Date!
    private var messages: [GroupPlanMessage] = []
    private var stores: [GroupPlanStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "group-plan-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeGroupPlanServer(yourName: "Sofia")
        clock = ManualSleeper()
        now = at(8)
        messages = []
        stores = []
        PlanditStore.shareUpdateDelay = .milliseconds(50)
    }

    override func tearDown() async throws {
        stores.forEach { $0.close() }
        await server.release()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 20) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func day(_ date: Int = 20) -> DayPlan {
        let places: [(Place, Int)] = [
            (SampleData.hungarianPastry, 45), (SampleData.met, 90), (SampleData.highLine, 60),
            (SampleData.losTacos, 45), (SampleData.washingtonSquare, 60),
        ]
        var stops: [PlanStop] = []
        var legs: [TravelLeg] = []
        for (place, minutes) in places {
            var stop = PlanStop(place: place, start: at(9, 30, day: date), durationMinutes: minutes, estimatedCost: 5, status: .upcoming)
            if let previous = stops.last {
                let leg = TravelLeg.estimate(from: previous, to: stop, travel: .walkAndTransit)
                legs.append(leg)
                stop.start = previous.end.addingTimeInterval(TimeInterval(leg.minutes * 60))
            }
            stops.append(stop)
        }
        return DayPlan(date: at(9, day: date), title: "Uptown to the Village", budget: 60, stops: stops, legs: legs)
    }

    /// `listening: false` is the app at launch: no screen has set `onMessage` yet.
    private func makeStore(userID: String = "user-1", in folder: URL? = nil, listening: Bool = true) -> GroupPlanStore {
        let clock = clock!
        let store = GroupPlanStore(
            userID: userID, server: server, directory: folder ?? directory, calendar: calendar,
            now: { [unowned self] in self.now }, sleep: { try await clock.sleep($0) },
            onMessage: listening ? { [unowned self] in self.messages.append($0) } : nil
        )
        stores.append(store)
        return store
    }

    private func listen(to store: GroupPlanStore) {
        store.onMessage = { [unowned self] in self.messages.append($0) }
    }

    /// Maya's group with Jordan and you; the store has fetched it at version 1.
    private func joinedGroup(date: String = "2026-11-20", plan: DayPlan? = nil, store: GroupPlanStore? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async -> (GroupPlanStore, UUID) {
        let id = await server.seedGroup(plan: plan ?? day(), date: date, organizer: "Maya", others: ["Jordan"])
        let store = store ?? makeStore()
        await store.refreshList()
        XCTAssertNotNil(store.group(id)?.plan, "fetched", file: file, line: line)
        return (store, id)
    }

    private func serverPlan(_ id: UUID) async -> DayPlan? { await server.info(id)?.plan }
    private func shown(_ store: GroupPlanStore, _ id: UUID) throws -> DayPlan { try XCTUnwrap(store.group(id)?.plan) }

    private func applied(_ edit: PlanEdit, to plan: DayPlan) -> DayPlan? {
        guard case .applied(let result) = PlanEdit.apply(edit, to: plan, now: now, calendar: calendar) else { return nil }
        return result
    }

    /// The server's plan, failing the test when the group is gone.
    private func requirePlan(_ id: UUID, file: StaticString = #filePath, line: UInt = #line) async throws -> DayPlan {
        let plan = await serverPlan(id)
        return try XCTUnwrap(plan, file: file, line: line)
    }

    /// Other members' edits on the server's copy, by the same rules. A value, so a fake server's
    /// trigger can run one.
    private struct Members: Sendable {
        let server: FakeGroupPlanServer
        let now: Date
        let calendar: Calendar

        @discardableResult
        @MainActor func edit(_ name: String?, _ id: UUID, _ make: (DayPlan) -> PlanEdit?) async -> DayPlan? {
            guard let plan = await server.info(id)?.plan, let edit = make(plan),
                  case .applied(let result) = PlanEdit.apply(edit, to: plan, now: now, calendar: calendar) else {
                XCTFail("the member's edit didn't apply")
                return nil
            }
            await server.change(id, by: name, kind: edit.kind, stopIDs: edit.stopIDs(before: plan, after: result), plan: result)
            return result
        }

        @discardableResult
        @MainActor func removes(_ index: Int, in id: UUID, by name: String) async -> UUID? {
            let removed = await server.info(id)?.plan.stops[index].id
            await edit(name, id) { PlanEdit.removing($0.stops[index].id, in: $0, travel: .walkAndTransit) }
            return removed
        }

        @discardableResult
        @MainActor func adds(_ place: Place, after index: Int?, in id: UUID, by name: String) async -> UUID {
            let stop = PlanStop(place: place, start: now, durationMinutes: 30, estimatedCost: 4, status: .upcoming)
            await edit(name, id) { plan -> PlanEdit? in
                let slot: PlanEdit.Slot = index.map { .after(plan.stops[$0].id) } ?? .end
                return .add(stop: stop, slot: slot, travel: .walkAndTransit)
            }
            return stop.id
        }

        @MainActor func retitle(_ id: UUID, _ title: String, by name: String) async {
            guard var plan = await server.info(id)?.plan else { return }
            plan.title = title
            await server.change(id, by: name, kind: "title", stopIDs: [], plan: plan)
        }
    }

    private var members: Members { Members(server: server, now: now, calendar: calendar) }

    @discardableResult
    private func mayaRemoves(_ index: Int, in id: UUID, by name: String = "Maya") async -> UUID? {
        await members.removes(index, in: id, by: name)
    }

    @discardableResult
    private func mayaAdds(_ place: Place, after index: Int?, in id: UUID, by name: String = "Maya") async -> UUID {
        await members.adds(place, after: index, in: id, by: name)
    }

    private func retitle(_ id: UUID, _ title: String, by name: String) async {
        await members.retitle(id, title, by: name)
    }

    private func removeEdit(_ store: GroupPlanStore, _ id: UUID, _ index: Int) throws -> PlanEdit {
        let plan = try shown(store, id)
        return try XCTUnwrap(PlanEdit.removing(plan.stops[index].id, in: plan, travel: .walkAndTransit))
    }

    private func addEdit(_ place: Place, note: String? = nil) -> PlanEdit {
        .add(stop: PlanStop(place: place, start: now, durationMinutes: 30, estimatedCost: 0, note: note, status: .upcoming), slot: .end, travel: .walkAndTransit)
    }

    private func timeEdit(_ store: GroupPlanStore, _ id: UUID, _ index: Int, minutes: Int) throws -> PlanEdit {
        let stop = try shown(store, id).stops[index]
        return .setTime(stopID: stop.id, start: stop.start, durationMinutes: minutes, moveLaterStops: true)
    }

    private func waitUntilSent(_ store: GroupPlanStore, _ id: UUID, file: StaticString = #filePath, line: UInt = #line) async {
        await eventually("every edit sent", file: file, line: line) { (store.group(id)?.pendingEdits ?? 0) == 0 }
        await settle(5)
    }

    private func cacheURL(_ userID: String = "user-1") -> URL { GroupPlanStore.cacheURL(for: userID, in: directory) }

    private func cacheText(_ userID: String = "user-1") -> String {
        (try? String(contentsOf: cacheURL(userID), encoding: .utf8)) ?? ""
    }

    /// The pending edits the cache file holds for a group, as JSON.
    private func cachedPending(_ id: UUID) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL())) as? [String: Any]
        let groups = try XCTUnwrap(object?["groups"] as? [[String: Any]])
        let group = try XCTUnwrap(groups.first { ($0["id"] as? String) == id.uuidString })
        return try XCTUnwrap(group["pending"] as? [[String: Any]])
    }

    /// Today's own plan, dated now so its rollover never runs; filing a group day must not touch it.
    private func personalStore(storage: SnapshotStore? = nil) -> PlanditStore {
        var today = day(21)
        today.date = Date()
        today.title = "My own day"
        let storage = storage ?? SnapshotStore(url: directory.appending(path: "plandit-store-\(UUID().uuidString).json"))
        return PlanditStore(today: today, saved: [], profile: SampleData.profile, pastPlans: [], visited: [], storage: storage, routes: NoRoutes())
    }

    private func redraws(_ store: GroupPlanStore) -> Flag {
        let flag = Flag()
        withObservationTracking { _ = store.groups } onChange: { flag.raise() }
        return flag
    }

    // MARK: - 2.2 The rebase loop

    /// RB-1: a 409 once; the second PUT has the server's version and `apply(edit, serverPlan)`.
    func testRB1_AConflictIsRebasedOntoTheServersPlanAndSentAgain() async throws {
        let (store, id) = await joinedGroup()
        let added = await mayaAdds(SampleData.littleIsland, after: 3, in: id)
        let v2 = try await requirePlan(id)
        let mine = try removeEdit(store, id, 1)

        XCTAssertEqual(store.apply(mine, to: id), .queued)
        await waitUntilSent(store, id)

        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2])
        XCTAssertEqual(updates.first?.editId, updates.last?.editId, "the same edit, sent again")
        XCTAssertEqual(updates.last?.plan, applied(mine, to: v2))
        XCTAssertEqual(updates.last?.edit.kind, "remove")
        let state = try XCTUnwrap(store.group(id))
        XCTAssertEqual(state.plan, updates.last?.plan, "the local plan is what was sent")
        XCTAssertEqual(state.version, 3)
        XCTAssertTrue(state.plan?.stops.contains { $0.id == added } ?? false)
        let info = await server.info(id)
        XCTAssertEqual(info?.version, 3)
        XCTAssertEqual(info?.plan, updates.last?.plan)
        XCTAssertTrue(messages.isEmpty)
    }

    /// RB-2, N-3: three 409s in a row; exactly 3 PUTs, then the latest plan and a message.
    func testRB2_ThreeConflictsInARowShowTheLatestPlanAndSaySo() async throws {
        let (store, id) = await joinedGroup()
        for round in 1...3 {
            let members = members
            await server.beforeNext(.put) { await members.retitle(id, "Maya's take \(round)", by: "Maya") }
        }

        store.apply(try removeEdit(store, id, 1), to: id)
        await waitUntilSent(store, id)

        let puts = await server.count(.put)
        XCTAssertEqual(puts, 3)
        let latest = await serverPlan(id)
        XCTAssertEqual(latest?.title, "Maya's take 3")
        XCTAssertEqual(store.group(id)?.plan, latest, "the latest plan, without the edit")
        XCTAssertEqual(messages.map(\.kind), [.keptChanging], "never a silent drop")
        XCTAssertFalse(messages.first?.text.isEmpty ?? true)
        clock.advance(by: .seconds(600))
        await settle()
        let after = await server.count(.put)
        XCTAssertEqual(after, 3)
    }

    /// RB-3, MF-C: the message names who removed the stop (from the 409's edits), not the last editor.
    func testRB3_AnEditToAStopSomeoneRemovedIsDroppedNamingWhoRemovedIt() async throws {
        let (store, id) = await joinedGroup()
        let mine = try timeEdit(store, id, 2, minutes: 90)
        let removedID = await mayaRemoves(2, in: id)
        let removed = try XCTUnwrap(removedID)
        await retitle(id, "Jordan's title", by: "Jordan")

        store.apply(mine, to: id)
        await waitUntilSent(store, id)

        let puts = await server.count(.put)
        XCTAssertEqual(puts, 1, "no second PUT")
        XCTAssertEqual(messages.map(\.kind), [.editsNotMade(count: 1, author: "Maya", reason: .stopGone(removed))])
        XCTAssertTrue(messages.first?.text.contains("Maya removed that stop") ?? false, messages.first?.text ?? "")
        let latest = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, latest, "the server's plan")
    }

    /// RB-3, contract: `editsFrom` past the base means some edits are missing, so no name is guessed.
    func testRB3_WhenTheServersListIsIncompleteNoNameIsGuessed() async throws {
        let (store, id) = await joinedGroup()
        let mine = try timeEdit(store, id, 2, minutes: 90)
        let removedID = await mayaRemoves(2, in: id)
        let removed = try XCTUnwrap(removedID)
        await retitle(id, "Jordan's title", by: "Jordan")
        await server.forgetEdits(id, through: 2)

        store.apply(mine, to: id)
        await waitUntilSent(store, id)

        XCTAssertEqual(messages.map(\.kind), [.editsNotMade(count: 1, author: nil, reason: .stopGone(removed))])
        XCTAssertFalse(messages.first?.text.contains("Maya") ?? true)
        XCTAssertFalse(messages.first?.text.contains("Jordan") ?? true)
    }

    /// RB-4: E2 waits for E1, then goes with E1's version as its base; both land in order.
    func testRB4_ASecondEditWaitsForTheFirstAndGoesOnTopOfIt() async throws {
        let (store, id) = await joinedGroup()
        await server.holdNext(.put)
        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("the first PUT is out") { await self.server.heldCount == 1 }

        store.apply(try removeEdit(store, id, 2), to: id)
        await settle()

        let whileOut = await server.count(.put)
        XCTAssertEqual(whileOut, 1, "E2 isn't sent until E1 is answered")
        XCTAssertEqual(store.group(id)?.plan?.stops.count, 3, "both show at once")
        await server.release()
        await waitUntilSent(store, id)
        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2])
        XCTAssertNotEqual(updates.first?.editId, updates.last?.editId)
        let final = await serverPlan(id)
        XCTAssertEqual(final?.stops.count, 3)
        XCTAssertEqual(store.group(id)?.plan, final)
        XCTAssertEqual(store.group(id)?.version, 3)
    }

    /// RB-4: on E1's 409, E1 is rebased first, then E2 goes on top of it.
    func testRB4_OnAConflictTheFirstIsRebasedThenTheSecondGoesOnTop() async throws {
        let (store, id) = await joinedGroup()
        let added = await mayaAdds(SampleData.littleIsland, after: 4, in: id)
        let first = try removeEdit(store, id, 1)
        store.apply(first, to: id)
        let second = try removeEdit(store, id, 2)
        store.apply(second, to: id)

        await waitUntilSent(store, id)

        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2, 3])
        XCTAssertEqual(updates[0].editId, updates[1].editId)
        XCTAssertNotEqual(updates[1].editId, updates[2].editId)
        let final = try await requirePlan(id)
        XCTAssertEqual(final.stops.count, 4)
        XCTAssertTrue(final.stops.contains { $0.id == added }, "Maya's stop is kept")
        XCTAssertEqual(store.group(id)?.plan, final)
    }

    /// RB-5: two edits to a stop someone removed go with one message; an unrelated third lands.
    func testRB5_EditsToAStopSomeoneRemovedGoWithOneMessageAndAnUnrelatedOneLands() async throws {
        let (store, id) = await joinedGroup()
        let plan = try shown(store, id)
        let target = plan.stops[2]
        let unrelated = plan.stops[4].id
        let removedID = await mayaRemoves(2, in: id)
        let removed = try XCTUnwrap(removedID)
        XCTAssertEqual(removed, target.id)

        store.apply(.setTime(stopID: target.id, start: target.start, durationMinutes: 90, moveLaterStops: true), to: id)
        store.apply(.move(stopID: target.id, after: plan.stops[3].id, travel: .walkAndTransit), to: id)
        store.apply(try XCTUnwrap(PlanEdit.removing(unrelated, in: try shown(store, id), travel: .walkAndTransit)), to: id)
        await waitUntilSent(store, id)

        XCTAssertEqual(messages.map(\.kind), [.editsNotMade(count: 2, author: "Maya", reason: .stopGone(target.id))])
        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2], "E1's 409, then E3")
        let final = await serverPlan(id)
        XCTAssertEqual(final?.stops.map(\.id), plan.stops.map(\.id).filter { $0 != target.id && $0 != unrelated })
        XCTAssertEqual(store.group(id)?.plan, final)
    }

    /// RB-6: a poll brings v+1 while the PUT is out; the edit stays on screen, and the 409 is handled.
    func testRB6_APollWhileThePutIsOutKeepsTheEditOnScreen() async throws {
        let (store, id) = await joinedGroup()
        let mine = try removeEdit(store, id, 1)
        let gone = try shown(store, id).stops[1].id
        let members = members
        await server.beforeNext(.put) { await members.adds(SampleData.littleIsland, after: 4, in: id, by: "Maya") }
        await server.holdNext(.put)

        store.apply(mine, to: id)
        await eventually("the PUT is out") { await self.server.heldCount == 1 }
        await store.refresh(id)

        let shown = try shown(store, id)
        XCTAssertEqual(store.group(id)?.version, 2)
        XCTAssertFalse(shown.stops.contains { $0.id == gone }, "the edit doesn't flicker away")
        XCTAssertTrue(shown.stops.contains { $0.place.name == SampleData.littleIsland.name })
        await server.release()
        await waitUntilSent(store, id)
        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2])
        let final = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, final)
        XCTAssertEqual(store.group(id)?.version, 3)
    }

    /// RB-7: a poll answered before the PUT landed arrives after it; ignored, never going back.
    func testRB7_AStalePollAfterThePutLandsIsIgnored() async throws {
        let (store, id) = await joinedGroup()
        await mayaAdds(SampleData.littleIsland, after: 4, in: id)
        await server.holdNext(.fetch)
        let poll = Task { await store.refresh(id) }
        await eventually("the poll is out") { await self.server.heldCount == 1 }

        store.apply(try removeEdit(store, id, 1), to: id)
        await waitUntilSent(store, id)
        XCTAssertEqual(store.group(id)?.version, 3)
        let v3 = await serverPlan(id)
        await server.release()
        _ = await poll.value

        XCTAssertEqual(store.group(id)?.version, 3, "never back to 2")
        XCTAssertEqual(store.group(id)?.plan, v3)
    }

    /// RB-8, MF-B: the server took the edit but the answer was lost; the retry keeps the `editId`,
    /// and the stop is there once.
    func testRB8_ALostAnswerIsRetriedWithTheSameEditIDAndAddsTheStopOnce() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .lostAfterSaving)

        store.apply(addEdit(SampleData.littleIsland), to: id)
        await eventually("the retry waits") { self.clock.sleeping == 1 }
        XCTAssertEqual(store.group(id)?.pendingEdits, 1, "kept")
        let landed = await server.info(id)?.version
        XCTAssertEqual(landed, 2, "the server has it")
        clock.advance(by: .seconds(60))
        await waitUntilSent(store, id)
        await eventually("the server's plan is fetched") { store.group(id)?.version == 2 }

        let updates = await server.updates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.editId, updates.last?.editId)
        let stored = try await requirePlan(id)
        XCTAssertEqual(stored.stops.filter { $0.place.name == SampleData.littleIsland.name }.count, 1)
        XCTAssertEqual(store.group(id)?.plan, stored)
        let version = await server.info(id)?.version
        XCTAssertEqual(version, 2, "no second version")
    }

    /// RB-8, MF-B: an edit stored earlier (its answer lost) stays on screen until a fetch brings the
    /// server's plan with it, however many fetches fail first; it isn't sent again.
    func testRB8_AnEditStoredEarlierStaysShownUntilAFetchBringsIt() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .lostAfterSaving)
        store.apply(addEdit(SampleData.littleIsland), to: id)
        await eventually("the retry waits") { self.clock.sleeping == 1 }
        let fetches = await server.count(.fetch)
        await server.script(.fetch, .network)
        await server.script(.fetch, .network)

        clock.advance(by: .seconds(60))
        await eventually("the retry's 200, then two fetches with no answer") { await self.server.count(.fetch) == fetches + 2 }
        await settle()

        XCTAssertEqual(try shown(store, id).stops.filter { $0.place.name == SampleData.littleIsland.name }.count, 1, "still shown")
        XCTAssertEqual(store.group(id)?.version, 1)
        await eventually("waiting to fetch again") { self.clock.sleeping == 1 }
        clock.advance(by: .seconds(60))
        await eventually("the server's plan") { store.group(id)?.version == 2 }
        await waitUntilSent(store, id)

        let stored = try await requirePlan(id)
        XCTAssertEqual(store.group(id)?.plan, stored)
        XCTAssertEqual(stored.stops.filter { $0.place.name == SampleData.littleIsland.name }.count, 1)
        let puts = await server.count(.put)
        XCTAssertEqual(puts, 2, "not sent again")
    }

    /// RB-8, MF-B: the server took the edit but the answer was lost, then someone else changed that
    /// stop. The server's list of edits says it was stored, so there's no message.
    func testRB8_ALandedEditIsNotReportedAsNotMadeWhenTheStopChangedSince() async throws {
        let (store, id) = await joinedGroup()
        let stop = try shown(store, id).stops[1].id
        await server.script(.put, .lostAfterSaving)
        store.apply(try XCTUnwrap(PlanEdit.status(.arrive, stopID: stop, in: try shown(store, id))), to: id)
        await eventually("the retry waits") { self.clock.sleeping == 1 }
        let landed = await server.info(id)?.version
        XCTAssertEqual(landed, 2, "the server has the arrive")
        await members.edit("Maya", id) { PlanEdit.status(.complete, stopID: stop, in: $0) }
        await store.refresh(id)
        clock.advance(by: .seconds(60))
        await waitUntilSent(store, id)

        XCTAssertEqual(messages.map(\.kind), [], "the arrive landed at v2, yet: \(messages.map(\.text))")
        let updates = await server.updates
        XCTAssertEqual(updates.count, 2, "the server was asked")
        XCTAssertEqual(updates.first?.editId, updates.last?.editId)
        let version = await server.info(id)?.version
        XCTAssertEqual(version, 3, "nothing stored again")
        let latest = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, latest)
    }

    /// RB-8: the answer was lost and the edit wasn't stored, then someone else changed that stop.
    /// The message comes only once the server says it doesn't have the edit (its 409), naming who.
    func testRB8_AnEditThatDidntLandIsReportedOnceTheServerSaysSo() async throws {
        let (store, id) = await joinedGroup()
        let stop = try shown(store, id).stops[1].id
        await server.script(.put, .network)
        store.apply(try XCTUnwrap(PlanEdit.status(.arrive, stopID: stop, in: try shown(store, id))), to: id)
        await eventually("the retry waits") { self.clock.sleeping == 1 }
        await members.edit("Maya", id) { PlanEdit.status(.complete, stopID: stop, in: $0) }
        await store.refresh(id)
        clock.advance(by: .seconds(60))
        await waitUntilSent(store, id)

        let updates = await server.updates
        XCTAssertEqual(updates.count, 2, "the server was asked")
        XCTAssertEqual(updates.first?.editId, updates.last?.editId)
        let version = await server.info(id)?.version
        XCTAssertEqual(version, 2, "nothing stored")
        XCTAssertEqual(messages.map(\.kind), [.editsNotMade(count: 1, author: "Maya", reason: .stopChanged(stop))])
        let latest = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, latest)
    }

    /// RB-9: 404 on the PUT drops the group, its edits and its cache, with a message; no retry.
    func testRB9_A404OnThePutDropsTheGroupWithAMessage() async throws {
        let (store, id) = await joinedGroup()
        await server.removeYou(from: id)

        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("the group is gone") { store.group(id) == nil }

        XCTAssertEqual(messages.map(\.kind), [.groupGone])
        XCTAssertFalse(cacheText().contains(id.uuidString))
        clock.advance(by: .seconds(600))
        await settle()
        let puts = await server.count(.put)
        XCTAssertEqual(puts, 1, "no retry")
    }

    /// RB-10: a 400 drops the edit with the server's words; the plan is the server's; no loop.
    func testRB10_ARefusedEditIsDroppedWithTheServersWords() async throws {
        let (store, id) = await joinedGroup()
        let before = store.group(id)?.plan
        await server.setDayOver(id)

        store.apply(try removeEdit(store, id, 1), to: id)
        await waitUntilSent(store, id)

        XCTAssertEqual(messages.map(\.kind), [.editRefused("This plan's day is over, so it can't be changed.")])
        XCTAssertEqual(store.group(id)?.plan, before, "back to the server's plan")
        clock.advance(by: .seconds(600))
        await settle()
        let puts = await server.count(.put)
        XCTAssertEqual(puts, 1, "no loop")
    }

    /// RB-10: a 413 drops that edit with a message, and the next one still lands.
    func testRB10_AnEditThatMakesThePlanTooBigIsDroppedAndTheNextLands() async throws {
        let (store, id) = await joinedGroup()
        store.apply(addEdit(SampleData.littleIsland, note: String(repeating: "x", count: 70_000)), to: id)
        store.apply(try removeEdit(store, id, 1), to: id)

        await waitUntilSent(store, id)

        XCTAssertEqual(messages.map(\.kind), [.planTooLarge(FakeGroupPlanServer.tooLargeDetail)])
        let final = try await requirePlan(id)
        XCTAssertEqual(final.stops.count, 4)
        XCTAssertFalse(final.stops.contains { $0.place.name == SampleData.littleIsland.name })
        XCTAssertEqual(store.group(id)?.plan, final)
    }

    /// RB-11: an answer this build can't read; the last good plan and the edit stay, nothing is PUT
    /// over it, and there's no loop.
    func testRB11_AnUnreadableAnswerKeepsTheLastGoodPlanAndNeverPutsOverIt() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .unreadable)

        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("read-only") { store.group(id)?.isReadOnly == true }

        XCTAssertEqual(store.group(id)?.pendingEdits, 1, "kept, never dropped silently")
        XCTAssertEqual(store.apply(try removeEdit(store, id, 2), to: id), .unavailable)
        clock.advance(by: .seconds(600))
        await settle()
        let puts = await server.count(.put)
        XCTAssertEqual(puts, 1)
        XCTAssertEqual(messages.map(\.kind), [.readOnly])
        XCTAssertTrue(cacheText().contains(id.uuidString), "the cache stays")
    }

    /// RB-11: a GET this build can't read keeps the cached plan, and nothing is PUT over it.
    func testRB11_AnUnreadablePollKeepsTheCachedPlan() async throws {
        let (store, id) = await joinedGroup()
        let before = store.group(id)?.plan
        await mayaRemoves(1, in: id)
        await server.script(.fetch, .unreadable)

        await store.refresh(id)

        XCTAssertEqual(store.group(id)?.plan, before)
        XCTAssertEqual(store.group(id)?.isReadOnly, true)
        XCTAssertEqual(store.apply(try removeEdit(store, id, 2), to: id), .unavailable)
    }

    // MARK: - 2.3 Polling

    /// POL-1: a GET at appear, at 15 s and at 30 s; none at 14.9 s.
    func testPOL1_TheGroupOnScreenIsFetchedAtOnceThenEvery15Seconds() async throws {
        let (store, id) = await joinedGroup()
        let start = await server.count(.fetch)

        store.show(id)
        await eventually("a GET at appear") { await self.server.count(.fetch) == start + 1 && self.clock.sleeping == 1 }
        clock.advance(by: .milliseconds(14_900))
        await settle()
        let early = await server.count(.fetch)
        XCTAssertEqual(early, start + 1, "none at 14.9 s")
        clock.advance(by: .milliseconds(100))
        await eventually("a GET at 15 s") { await self.server.count(.fetch) == start + 2 && self.clock.sleeping == 1 }
        clock.advance(by: .seconds(15))
        await eventually("a GET at 30 s") { await self.server.count(.fetch) == start + 3 }
        XCTAssertTrue(clock.requested.allSatisfy { $0 == .seconds(15) }, "\(clock.requested)")
    }

    /// POL-2: a 304 changes nothing anyone observes.
    func testPOL2_A304RedrawsNothing() async throws {
        let (store, id) = await joinedGroup()
        let redrawn = redraws(store)

        await store.refresh(id)

        let fetch = await server.fetches.last
        XCTAssertEqual(fetch?.etag, "\"1.1\"")
        XCTAssertFalse(redrawn.isRaised)
    }

    /// POL-3: a newer plan replaces the old one; the ETag goes back exactly as it came, `W/` and all,
    /// and only for a plan the app holds.
    func testPOL3_ANewerPlanReplacesTheOldAndItsETagGoesBackExactly() async throws {
        await server.useWeakETags()
        let (store, id) = await joinedGroup()
        await mayaRemoves(1, in: id)

        await store.refresh(id)
        let latest = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, latest)
        XCTAssertEqual(store.group(id)?.version, 2)
        await store.refresh(id)

        let fetches = await server.fetches
        XCTAssertEqual(fetches.map(\.etag), [nil, "W/\"1.1\"", "W/\"2.1\""])
    }

    /// POL-4: a 200 with the version already held (the URL cache's doing) redraws nothing.
    func testPOL4_TheSameVersionAgainRedrawsNothing() async throws {
        let (store, id) = await joinedGroup()
        let redrawn = redraws(store)
        await server.script(.fetch, .fullAnswer)

        await store.refresh(id)

        XCTAssertFalse(redrawn.isRaised)
    }

    /// POL-5: no polls in the background or off screen; one at once back in the foreground.
    func testPOL5_NoPollsInTheBackgroundOrOffScreenAndOneAtOnceOnForeground() async throws {
        let (store, id) = await joinedGroup()
        let start = await server.count(.fetch)
        store.show(id)
        await eventually("polling") { await self.server.count(.fetch) == start + 1 && self.clock.sleeping == 1 }

        store.appWillResign()
        await eventually("the poll stops") { self.clock.sleeping == 0 }
        clock.advance(by: .seconds(120))
        await settle()
        var count = await server.count(.fetch)
        XCTAssertEqual(count, start + 1, "none in the background")

        store.appBecameActive()
        await eventually("a GET at once on foreground") { await self.server.count(.fetch) == start + 2 }
        await settle()
        count = await server.count(.fetch)
        XCTAssertEqual(count, start + 2)

        store.hide(id)
        await eventually("the poll stops") { self.clock.sleeping == 0 }
        clock.advance(by: .seconds(120))
        await settle()
        count = await server.count(.fetch)
        XCTAssertEqual(count, start + 2, "none off screen")
    }

    /// POL-6: a GET held past 15 s is never overlapped by a second one.
    func testPOL6_AHeldPollIsNeverOverlapped() async throws {
        let (store, id) = await joinedGroup()
        let start = await server.count(.fetch)
        await server.holdNext(.fetch)

        store.show(id)
        await eventually("the GET is out") { await self.server.heldCount == 1 }
        clock.advance(by: .seconds(15))
        clock.advance(by: .seconds(15))
        await settle()
        store.appBecameActive()
        await settle()

        var count = await server.count(.fetch)
        XCTAssertEqual(count, start + 1, "never a second GET while one is out")
        await server.release()
        await eventually("polling goes on") { self.clock.sleeping == 1 }
        count = await server.count(.fetch)
        XCTAssertEqual(count, start + 1)
    }

    /// POL-7: a network error or 5xx keeps the cache, and polling goes on with backoff.
    func testPOL7_AFailedPollKeepsThePlanAndBacksOff() async throws {
        let (store, id) = await joinedGroup()
        let before = store.group(id)?.plan
        await server.script(.fetch, .network)
        await server.script(.fetch, .status(503))

        store.show(id)
        await eventually("backed off once") { self.clock.requested == [.seconds(30)] }
        XCTAssertEqual(store.group(id)?.plan, before, "the cache is kept")
        clock.advance(by: .seconds(30))
        await eventually("backed off twice") { self.clock.requested == [.seconds(30), .seconds(60)] }
        clock.advance(by: .seconds(60))
        await eventually("back to 15 s") { self.clock.requested == [.seconds(30), .seconds(60), .seconds(15)] }
        XCTAssertTrue(messages.isEmpty)
    }

    /// POL-8: only the group on screen polls; the list on foreground picks up a group joined elsewhere.
    func testPOL8_OnlyTheGroupOnScreenPollsAndTheListPicksUpNewGroups() async throws {
        let (store, first) = await joinedGroup()
        let second = await server.seedGroup(plan: day(), date: "2026-11-20", organizer: "Jordan")
        await store.refreshList()
        XCTAssertNotNil(store.group(second)?.plan)
        let start = await server.fetches.count

        store.show(first)
        await eventually("polling") { self.clock.sleeping == 1 }
        clock.advance(by: .seconds(15))
        await eventually("two polls") { await self.server.fetches.count == start + 2 }
        let polled = await server.fetches.dropFirst(start).map(\.id)
        XCTAssertEqual(Set(polled), [first])

        let third = await server.seedGroup(plan: day(), date: "2026-11-20", organizer: "Ana")
        store.appBecameActive()
        await eventually("the group joined on another phone") { store.group(third)?.plan != nil }
    }

    // MARK: - 2.4 Removed member or ended group

    /// REM-1: a poll's 404 removes the group from the store and the cache file; the message shows once.
    func testREM1_A404DropsTheGroupAndItsCacheWithOneMessage() async throws {
        let (store, id) = await joinedGroup()
        XCTAssertTrue(cacheText().contains(id.uuidString))
        store.show(id)
        await eventually("polling") { self.clock.sleeping == 1 }

        await server.endGroup(id)
        clock.advance(by: .seconds(15))
        await eventually("the group is gone") { store.group(id) == nil }

        XCTAssertFalse(cacheText().contains(id.uuidString))
        clock.advance(by: .seconds(60))
        await settle()
        XCTAssertEqual(messages.map(\.kind), [.groupGone])
        XCTAssertEqual(messages.first?.groupID, id)
    }

    /// REM-2: a 404 on one group leaves the others alone.
    func testREM2_A404OnOneGroupLeavesTheOthersAlone() async throws {
        let (store, first) = await joinedGroup()
        let second = await server.seedGroup(plan: day(), date: "2026-11-20", organizer: "Jordan")
        await store.refreshList()
        let other = store.group(second)

        await server.endGroup(first)
        await store.refresh(first)

        XCTAssertNil(store.group(first))
        XCTAssertEqual(store.group(second), other)
        XCTAssertTrue(cacheText().contains(second.uuidString))
    }

    /// REM-3: a group missing from the list is dropped.
    func testREM3_AGroupMissingFromTheListIsDropped() async throws {
        let (store, id) = await joinedGroup()
        await server.removeYou(from: id)

        await store.refreshList()

        XCTAssertNil(store.group(id))
        XCTAssertEqual(messages.map(\.kind), [.groupGone])
    }

    /// REM-4: closing (sign-out, deletion) stops every write; deleting the cache leaves nothing.
    func testREM4_AClosedStoreWritesNothingLateAndItsCacheIsGone() async throws {
        let (store, id) = await joinedGroup()
        await server.holdNext(.put)
        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("the PUT is out") { await self.server.heldCount == 1 }

        store.close()
        store.deleteCache()
        await server.release()
        await settle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL().path()))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(store.apply(try removeEdit(store, id, 2), to: id), .unavailable)
        await store.refreshList()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL().path()))
    }

    /// REM-5: each account's cache is its own file, never mixed.
    func testREM5_EachAccountHasItsOwnCache() async throws {
        let (_, id) = await joinedGroup()

        let other = makeStore(userID: "user-2")

        XCTAssertTrue(other.groups.isEmpty)
        XCTAssertNotEqual(cacheURL("user-1"), cacheURL("user-2"))
        XCTAssertFalse(cacheText("user-2").contains(id.uuidString))
        XCTAssertNotNil(makeStore(userID: "user-1").group(id)?.plan, "the first account's cache is still there")
    }

    // MARK: - 2.6 Rollover

    /// RO-1: at 4 AM New York time the morning after, one past plan with the group's id; its places
    /// are visited; today's own plan is untouched.
    func testRO1_AtFourTheNextMorningTheDayIsFiledWithTheGroupsID() async throws {
        let (store, id) = await joinedGroup()
        let history = personalStore()
        store.history = history
        let today = history.today

        now = at(3, 59, day: 21)
        store.rollOverIfNeeded()
        XCTAssertTrue(history.pastPlans.isEmpty, "not before 4 AM")
        XCTAssertEqual(store.group(id)?.isDayOver, false)
        now = at(4, day: 21)
        store.rollOverIfNeeded()

        XCTAssertEqual(history.pastPlans.map(\.id), [id])
        let plan = day()
        XCTAssertEqual(history.pastPlans.first?.stopCount, 5)
        XCTAssertEqual(history.pastPlans.first?.title, plan.title)
        XCTAssertEqual(history.pastPlans.first?.cost, plan.totalCost)
        XCTAssertEqual(Set(history.visited.map(\.name)), Set(plan.stops.map(\.place.name)))
        XCTAssertEqual(history.today, today, "today untouched")
        XCTAssertEqual(store.group(id)?.isDayOver, true)
    }

    /// RO-2: rollover at launch and again on foreground: still one.
    func testRO2_RollingOverTwiceFilesOnce() async throws {
        let (store, id) = await joinedGroup()
        let history = personalStore()
        store.history = history
        now = at(9, day: 21)

        store.rollOverIfNeeded()
        store.appBecameActive()
        store.rollOverIfNeeded()
        await settle()

        XCTAssertEqual(history.pastPlans.map(\.id), [id])
    }

    /// RO-3: phone A files the day and pushes; phone B pulls (last writer wins) and adds no other.
    func testRO3_APhoneThatPullsTheOthersRolloverDoesntAddAnother() async throws {
        let (phoneA, id) = await joinedGroup()
        let folderB = directory.appending(path: "phone-b")
        let phoneB = makeStore(in: folderB)
        await phoneB.refreshList()
        let historyA = personalStore()
        let historyB = personalStore()
        phoneA.history = historyA
        phoneB.history = historyB
        now = at(9, day: 21)

        phoneA.rollOverIfNeeded()
        historyB.replace(with: historyA.snapshot)
        phoneB.rollOverIfNeeded()

        XCTAssertEqual(historyB.pastPlans.filter { $0.id == id }.count, 1)
        XCTAssertEqual(historyB.pastPlans, historyA.pastPlans)
    }

    /// RO-4: both phones file the day before syncing; after push and pull, exactly one on both.
    func testRO4_TwoPhonesThatBothRolledOverEndWithOne() async throws {
        let (phoneA, id) = await joinedGroup()
        let phoneB = makeStore(in: directory.appending(path: "phone-b"))
        await phoneB.refreshList()
        let historyA = personalStore()
        let historyB = personalStore()
        phoneA.history = historyA
        phoneB.history = historyB
        now = at(9, day: 21)

        phoneA.rollOverIfNeeded()
        phoneB.rollOverIfNeeded()
        historyB.replace(with: historyA.snapshot)
        phoneB.rollOverIfNeeded()
        historyA.replace(with: historyB.snapshot)
        phoneA.rollOverIfNeeded()

        XCTAssertEqual(historyA.pastPlans.filter { $0.id == id }.count, 1)
        XCTAssertEqual(historyB.pastPlans.filter { $0.id == id }.count, 1)
    }

    /// RO-5 (N-8, decided): an edit still waiting at the end of the day is in the filed plan.
    func testRO5_AnEditStillWaitingAtTheEndOfTheDayIsInTheFiledPlan() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .network)
        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("offline, waiting to retry") { self.clock.sleeping == 1 }
        let history = personalStore()
        store.history = history

        now = at(4, day: 21)
        store.rollOverIfNeeded()

        XCTAssertEqual(history.pastPlans.map(\.id), [id])
        XCTAssertEqual(history.pastPlans.first?.stopCount, 4)
    }

    /// RO-6 (decided): a group that ended before the morning isn't filed.
    func testRO6_AGroupThatEndedBeforeTheMorningIsntFiled() async throws {
        let (store, id) = await joinedGroup()
        await server.endGroup(id)
        await store.refresh(id)
        let history = personalStore()
        store.history = history

        now = at(4, day: 21)
        store.rollOverIfNeeded()

        XCTAssertTrue(history.pastPlans.isEmpty)
    }

    /// RO-7: a group for a later day isn't filed until its own day is over.
    func testRO7_AGroupForALaterDayIsntFiledYet() async throws {
        let (store, id) = await joinedGroup(date: "2026-11-21", plan: day(21))
        let history = personalStore()
        store.history = history

        now = at(5, day: 21)
        store.rollOverIfNeeded()
        XCTAssertTrue(history.pastPlans.isEmpty)
        now = at(4, day: 22)
        store.rollOverIfNeeded()

        XCTAssertEqual(history.pastPlans.map(\.id), [id])
    }

    /// RO-8: the filed day is saved on the phone even when nothing is pushed (read-only sync), and
    /// taking an older copy later (after an app update) doesn't file it twice.
    func testRO8_TheFiledDayIsSavedOnThePhoneAndAnOlderCopyDoesntDuplicateIt() async throws {
        let (store, id) = await joinedGroup()
        let storage = SnapshotStore(url: directory.appending(path: "plandit-store-user-1.json"))
        let history = personalStore(storage: storage)
        store.history = history
        let older = history.snapshot

        now = at(9, day: 21)
        store.rollOverIfNeeded()
        await eventually("saved on the phone") { storage.load()?.pastPlans.map(\.id) == [id] }
        history.replace(with: older)
        store.rollOverIfNeeded()

        XCTAssertEqual(history.pastPlans.filter { $0.id == id }.count, 1)
    }

    // MARK: - 2.7 Offline and relaunch

    /// OFF-1: an offline edit shows at once and is in the cache file; back online it goes with its
    /// original base, then the 409 rebases it.
    func testOFF1_AnOfflineEditIsShownSavedAndRebasedWhenBackOnline() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .network)

        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("offline, waiting to retry") { self.clock.sleeping == 1 }

        XCTAssertEqual(store.group(id)?.plan?.stops.count, 4, "shown at once")
        let cached = try cachedPending(id)
        XCTAssertEqual(cached.count, 1)
        let sent = await server.updates
        XCTAssertEqual(cached.first?["editId"] as? String, sent.first?.editId.uuidString)
        XCTAssertEqual(cached.first?["madeOn"] as? Int, 1)
        XCTAssertNotNil(cached.first?["edit"])
        await mayaAdds(SampleData.littleIsland, after: 4, in: id)
        clock.advance(by: .seconds(60))
        await waitUntilSent(store, id)

        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 1, 2], "the original base, then the rebase")
        XCTAssertEqual(Set(updates.map(\.editId)).count, 1)
        let final = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, final)
        XCTAssertEqual(final?.stops.count, 5)
    }

    /// OFF-2: killed with an unsent edit; the relaunch sends it with the same `editId`.
    func testOFF2_ARelaunchSendsAnUnsentEditWithTheSameEditID() async throws {
        let (first, id) = await joinedGroup()
        await server.script(.put, .network)
        first.apply(try removeEdit(first, id, 1), to: id)
        await eventually("offline, waiting to retry") { self.clock.sleeping == 1 }
        first.close()

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.group(id)?.pendingEdits, 1)
        XCTAssertEqual(relaunched.group(id)?.plan?.stops.count, 4)
        await waitUntilSent(relaunched, id)

        let updates = await server.updates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.editId, updates.last?.editId)
        let final = await serverPlan(id)
        XCTAssertEqual(relaunched.group(id)?.plan, final)
        XCTAssertEqual(relaunched.group(id)?.version, 2)
    }

    /// OFF-3, MF-B: killed after the PUT went out but before its 200 was saved; the replay is
    /// already applied on the server, so the stop isn't added twice.
    func testOFF3_AnEditThatLandedJustBeforeTheAppQuitIsNotAddedAgain() async throws {
        let (first, id) = await joinedGroup()
        await server.holdNext(.put)
        first.apply(addEdit(SampleData.littleIsland), to: id)
        await eventually("the PUT is out") { await self.server.heldCount == 1 }
        first.close()
        await server.release()

        let relaunched = makeStore()
        await waitUntilSent(relaunched, id)
        await eventually("the server's plan") { relaunched.group(id)?.version == 2 }

        let updates = await server.updates
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.editId, updates.last?.editId)
        let version = await server.info(id)?.version
        XCTAssertEqual(version, 2, "already applied, not again")
        XCTAssertEqual(relaunched.group(id)?.plan?.stops.filter { $0.place.name == SampleData.littleIsland.name }.count, 1)
    }

    private static let dayOverDetail = "This plan's day is over, so it can't be changed."

    /// Edits waiting in the cache that the server refuses as the app opens, before any screen
    /// listens: first a stop too big to save (413), then `removals` stops removed on a day that's
    /// over (400). Returns the relaunched store once it has sent them all.
    private func messagesAtLaunch(removals: Int) async throws -> (GroupPlanStore, UUID) {
        let (first, id) = await joinedGroup()
        await server.script(.put, .network)
        first.apply(addEdit(SampleData.littleIsland, note: String(repeating: "x", count: 70_000)), to: id)
        for _ in 0..<removals { first.apply(try removeEdit(first, id, 1), to: id) }
        await eventually("offline, waiting to retry") { self.clock.sleeping == 1 }
        first.close()
        await server.setDayOver(id)

        let relaunched = makeStore(listening: false)
        await waitUntilSent(relaunched, id)
        XCTAssertTrue(messages.isEmpty, "nobody is listening yet")
        return (relaunched, id)
    }

    /// OFF-2: messages from before a screen listens (edits refused as the app opens) wait for it,
    /// and come in order.
    func testOFF2_MessagesFromBeforeAScreenListensWaitForItInOrder() async throws {
        let (store, id) = try await messagesAtLaunch(removals: 1)

        listen(to: store)

        XCTAssertEqual(messages.map(\.kind), [.planTooLarge(FakeGroupPlanServer.tooLargeDetail), .editRefused(Self.dayOverDetail)])
        XCTAssertEqual(messages.map(\.groupID), [id, id])
        listen(to: store)
        XCTAssertEqual(messages.count, 2, "each once")
    }

    /// Only the latest 3 wait; older ones are dropped.
    func testOFF2_OnlyTheLatestThreeMessagesWait() async throws {
        let (store, _) = try await messagesAtLaunch(removals: 3)

        listen(to: store)

        XCTAssertEqual(messages.map(\.kind), Array(repeating: .editRefused(Self.dayOverDetail), count: 3), "the oldest, too big, dropped")
    }

    /// REM-4: closing (sign-out) drops the messages waiting; none reach a screen afterwards.
    func testREM4_ClosingDropsTheMessagesWaiting() async throws {
        let (store, _) = try await messagesAtLaunch(removals: 1)

        store.close()
        listen(to: store)

        XCTAssertTrue(messages.isEmpty)
    }

    /// OFF-4: a corrupt cache file starts empty, then the list fills it, with no crash.
    func testOFF4_ACorruptCacheStartsEmptyAndFetchesTheList() async throws {
        let id = await server.seedGroup(plan: day(), date: "2026-11-20", organizer: "Maya")
        try Data("{ not json".utf8).write(to: cacheURL())

        let store = makeStore()
        XCTAssertTrue(store.groups.isEmpty)
        await store.refreshList()

        XCTAssertNotNil(store.group(id)?.plan)
    }

    /// OFF-5: removed while offline; the pending PUT gets 404, and the group goes with the message.
    func testOFF5_RemovedWhileOfflineThePendingEditIsDroppedWithTheMessage() async throws {
        let (store, id) = await joinedGroup()
        await server.script(.put, .network)
        store.apply(try removeEdit(store, id, 1), to: id)
        await eventually("offline, waiting to retry") { self.clock.sleeping == 1 }

        await server.removeYou(from: id)
        clock.advance(by: .seconds(60))
        await eventually("the group is gone") { store.group(id) == nil }

        XCTAssertEqual(messages.map(\.kind), [.groupGone])
        XCTAssertFalse(cacheText().contains(id.uuidString))
    }

    // MARK: - 2.5 Today switch, store level

    /// SW-1, SW-2: group edits and polls leave today's own plan byte-identical, never fire
    /// `onChange` (so nothing is pushed), and never update the `/p/` page.
    func testSW1_GroupEditsAndPollsNeverTouchThePersonalPlan() async throws {
        let (store, id) = await joinedGroup()
        let sharing = FakePlanSharing()
        let history = personalStore()
        history.sharing = sharing
        try await history.shareToday(showPrices: true, note: "")
        store.history = history
        try await Task.sleep(for: .milliseconds(400))
        var changes = 0
        history.onChange = { _ in changes += 1 }
        let before = history.encodedSnapshot
        let published = await sharing.published.count

        store.apply(try removeEdit(store, id, 1), to: id)
        store.apply(addEdit(SampleData.littleIsland), to: id)
        await mayaAdds(SampleData.joesPizza, after: 0, in: id)
        await store.refresh(id)
        await waitUntilSent(store, id)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(history.encodedSnapshot, before)
        XCTAssertEqual(changes, 0)
        let after = await sharing.published.count
        XCTAssertEqual(after, published, "no /p/ update")
    }

    /// SW-2: a personal edit sends nothing to the group.
    func testSW2_APersonalEditSendsNothingToTheGroup() async throws {
        let (store, id) = await joinedGroup()
        let history = personalStore()
        store.history = history

        history.removeStop(history.today.stops[1].id)
        try await Task.sleep(for: .milliseconds(400))

        let puts = await server.count(.put)
        XCTAssertEqual(puts, 0)
        let plan = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, plan)
    }

    /// SW-3, MF-F: undo after a poll brought another member's change; the change survives (group
    /// plans have no undo; personal undo never reaches them).
    func testSW3_PersonalUndoAfterARemoteChangeKeepsTheRemoteChange() async throws {
        let (store, id) = await joinedGroup()
        let history = personalStore()
        store.history = history
        history.removeStop(history.today.stops[1].id)
        XCTAssertNotNil(history.undo)
        let added = await mayaAdds(SampleData.littleIsland, after: 4, in: id)
        await store.refresh(id)

        history.undoLastChange()

        XCTAssertTrue(store.group(id)?.plan?.stops.contains { $0.id == added } ?? false)
        let plan = await serverPlan(id)
        XCTAssertEqual(store.group(id)?.plan, plan)
    }

    // MARK: - Making, joining and leaving

    func testCreatingFromAPlanMakesYouTheOrganizerOnce() async throws {
        let store = makeStore()
        let plan = day()

        let made = try await store.create(from: plan).get()
        let again = try await store.create(from: plan).get()

        XCTAssertEqual(made, again, "a double tap makes one group")
        XCTAssertEqual(store.groups.map(\.id), [made])
        let group = try XCTUnwrap(store.group(made))
        XCTAssertEqual(group.date, "2026-11-20")
        XCTAssertEqual(group.plan, plan)
        XCTAssertTrue(group.isOrganizer)
        XCTAssertNotNil(group.inviteUrl)
        XCTAssertEqual(group.members.map(\.name), ["Sofia"])
        let sent = await server.calls
        XCTAssertEqual(sent, [.create, .create])
    }

    func testPreviewThenJoinByLinkAndJoiningAgainChangesNothing() async throws {
        let id = await server.seedGroup(plan: day(), date: "2026-11-20", organizer: "Jordan", youAreMember: false)
        let info = await server.info(id)
        let token = try XCTUnwrap(info?.token)
        let store = makeStore()

        let preview = try await store.preview(token: token).get()
        let joined = try await store.join(token: token).get()
        let again = try await store.join(token: token).get()

        XCTAssertEqual(preview, GroupInvitePreview(organizerName: "Jordan", date: "2026-11-20", memberCount: 1))
        XCTAssertEqual(joined, id)
        XCTAssertEqual(again, id)
        XCTAssertEqual(store.groups.map(\.id), [id])
        XCTAssertEqual(store.group(id)?.members.map(\.name), ["Jordan", "Sofia"])
        XCTAssertFalse(store.group(id)?.isOrganizer ?? true)
        let gone = await store.preview(token: "fake-invite-that-doesnt-work")
        XCTAssertEqual(gone, .failure(.gone))
    }

    func testLeavingRemovesTheGroupWithoutAMessage() async throws {
        let (store, id) = await joinedGroup()

        try await store.leave(id).get()

        XCTAssertNil(store.group(id))
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(cacheText().contains(id.uuidString))
        let names = await server.info(id)?.memberNames
        XCTAssertEqual(names, ["Maya", "Jordan"])
        await store.refreshList()
        XCTAssertNil(store.group(id))
    }

    func testTheOrganizerCantLeaveButCanEndRemoveAndReplaceTheLink() async throws {
        let id = try await makeStore().create(from: day()).get()
        let store = stores[0]
        let jordan = await server.addMember("Jordan", to: id)
        await store.refresh(id)
        let oldLink = try XCTUnwrap(store.group(id)?.inviteUrl)

        let leave = await store.leave(id)
        XCTAssertEqual(leave.failureValue, .refused(FakeGroupPlanServer.organizerLeavesDetail))
        try await store.remove(member: jordan, from: id).get()
        XCTAssertEqual(store.group(id)?.members.map(\.name), ["Sofia"])
        let newLink = try await store.newInviteLink(id).get()
        XCTAssertNotEqual(newLink, oldLink)
        XCTAssertEqual(store.group(id)?.inviteUrl, newLink)
        try await store.end(id).get()

        XCTAssertNil(store.group(id))
        let ended = await server.info(id)
        XCTAssertNil(ended)
        XCTAssertTrue(messages.isEmpty)
    }

    /// The organizer's other phone made a new link. This phone's edit is answered with the newer
    /// members but no link, so the next refresh fetches the whole group, link included.
    func testANewLinkMadeOnAnotherPhoneArrivesAfterAnEdit() async throws {
        let id = try await makeStore().create(from: day()).get()
        let store = stores[0]
        let newLink = try await server.newInvite(id)
        XCTAssertNotNil(newLink)

        store.apply(try removeEdit(store, id, 1), to: id)
        await waitUntilSent(store, id)
        await store.refresh(id)

        XCTAssertEqual(store.group(id)?.inviteUrl, newLink, "not the old link, which no longer works")
    }

    /// The same through a 409, and after a relaunch: the cache keeps no ETag that would answer 304.
    func testANewLinkMadeOnAnotherPhoneArrivesAfterAConflictAndARelaunch() async throws {
        let id = try await makeStore().create(from: day()).get()
        let first = stores[0]
        let newLink = try await server.newInvite(id)
        await server.addMember("Jordan", to: id)
        await retitle(id, "Jordan's title", by: "Jordan")

        first.apply(try removeEdit(first, id, 1), to: id)
        await waitUntilSent(first, id)
        let updates = await server.updates
        XCTAssertEqual(updates.map(\.baseVersion), [1, 2], "a 409, then the rebase")
        XCTAssertEqual(first.group(id)?.members.map(\.name), ["Sofia", "Jordan"], "the 409's members")
        first.close()

        let relaunched = makeStore()
        await relaunched.refreshList()

        XCTAssertEqual(relaunched.group(id)?.inviteUrl, newLink)
        XCTAssertEqual(relaunched.group(id)?.members.map(\.name), ["Sofia", "Jordan"])
        XCTAssertEqual(relaunched.group(id)?.version, 3)
    }

    /// RO-1's boundary: 4 AM New York time the morning after, also across the clock change.
    func testAGroupDayEndsAtFourTheNextMorningInNewYork() {
        XCTAssertEqual(GroupPlanDay.end(of: "2026-11-20"), at(4, day: 21))
        let fallBack = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 4))
        XCTAssertEqual(GroupPlanDay.end(of: "2026-10-31"), fallBack)
        XCTAssertNil(GroupPlanDay.end(of: "Saturday"))
        XCTAssertEqual(GroupPlanDay.string(for: at(23, 59), calendar: calendar), "2026-11-20")
    }

    func testOfflineActionsSaySo() async throws {
        let store = makeStore()
        await server.script(.create, .network)

        let made = await store.create(from: day())

        XCTAssertEqual(made.failureValue, .offline)
        XCTAssertTrue(store.groups.isEmpty)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
