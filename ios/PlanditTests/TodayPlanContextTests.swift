import XCTest
@testable import Plandit

/// Today's actions go to the plan on screen: your own (`PlanditStore`, with Undo) or the selected
/// group plan (`GroupPlanStore.apply`), never both (SW-1, SW-2).
@MainActor final class TodayPlanContextTests: XCTestCase {
    private var directory: URL!
    private var server: FakeGroupPlanServer!
    private var groups: GroupPlanStore!
    private var store: PlanditStore!
    private var router: SheetRouter!
    private var messages: GroupMessages!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "today-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeGroupPlanServer(yourName: "Sofia")
        groups = GroupPlanStore(userID: "user-1", server: server, directory: directory)
        store = PlanditStore.sample()
        router = SheetRouter()
        messages = GroupMessages()
    }

    override func tearDown() async throws {
        groups.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private var today: String { GroupPlanDay.string(for: Date(), calendar: .current) }

    private func context(groups: GroupPlanStore?? = .none) -> TodayPlanContext {
        TodayPlanContext(store: store, groups: groups ?? self.groups, router: router, messages: messages, now: Date(), calendar: .current)
    }

    /// Maya's plan for today: the sample day with its own stop ids, every stop still ahead.
    private func mayasGroup() async -> UUID {
        await group(by: "Maya", others: ["Jordan"])
    }

    private func group(by organizer: String, others: [String] = []) async -> UUID {
        var plan = SampleData.dayPlan.withFreshStopIDs()
        plan.id = UUID()
        for index in plan.stops.indices { plan.stops[index].status = .upcoming }
        let id = await server.seedGroup(plan: plan, date: today, organizer: organizer, others: others)
        await groups.refreshList()
        XCTAssertNotNil(groups.group(id)?.plan)
        return id
    }

    func testWithoutGroupPlansTodayIsYourOwn() {
        let context = context(groups: .some(nil))
        XCTAssertEqual(context.choice, .mine)
        XCTAssertEqual(context.options, [])
        XCTAssertFalse(context.controls.startGroup)
        XCTAssertEqual(context.plan, store.today)
    }

    func testAGroupPlanIsOfferedAndShownWhenPicked() async {
        let id = await mayasGroup()
        let context = context()
        XCTAssertEqual(context.choice, .mine, "your own plan has stops")
        XCTAssertEqual(context.options.map(\.label), ["Mine", "Maya's plan"])
        context.select(.group(id))
        XCTAssertEqual(router.todayChoice, .group(id))
        XCTAssertEqual(context.group?.id, id)
        XCTAssertEqual(context.plan, groups.group(id)?.plan)
    }

    func testGroupEditsChangeTheGroupNotYourPlan() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.group(id))
        let met = try XCTUnwrap(groups.group(id)?.plan?.stops[1].id)
        let ownBefore = store.today

        context.remove(met)
        context.arrive(at: try XCTUnwrap(groups.group(id)?.plan?.stops[0].id))

        let shown = try XCTUnwrap(groups.group(id)?.plan)
        XCTAssertNil(shown.stop(id: met))
        XCTAssertEqual(shown.stops[0].status, .now)
        XCTAssertEqual(store.today, ownBefore, "your own plan is untouched")
        XCTAssertFalse(store.canUndo, "no Undo for group edits")
    }

    func testYourEditsLeaveTheGroupAlone() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.mine)
        let groupBefore = groups.group(id)?.plan
        let tacos = store.today.stops[3].id

        context.remove(tacos)

        XCTAssertNil(store.today.stop(id: tacos))
        XCTAssertEqual(groups.group(id)?.plan, groupBefore)
        XCTAssertEqual(groups.group(id)?.pendingEdits, 0)
    }

    func testReorderInAGroupSendsMovesNotAWholeList() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.group(id))
        let base = try XCTUnwrap(groups.group(id)?.plan)
        let ids = base.stops.map(\.id)
        let order = [ids[1], ids[0]] + ids[2...]

        XCTAssertEqual(context.previewReorder(order, from: base).stops.map(\.id), order)
        context.reorder(order, from: base)

        XCTAssertEqual(groups.group(id)?.plan?.stops.map(\.id), order)
        XCTAssertNotEqual(store.today.stops.map(\.id), order, "your own plan keeps its order")
    }

    func testTravelForTheRestOfTheDayInAGroup() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.group(id))

        context.chooseTravelForRestOfDay(.drive)

        let legs = try XCTUnwrap(groups.group(id)?.plan?.legs)
        XCTAssertFalse(legs.isEmpty)
        XCTAssertTrue(legs.allSatisfy { $0.mode == .drive && $0.isChosen })
        XCTAssertFalse(store.today.legs.allSatisfy { $0.mode == .drive })
    }

    func testAnEditThatNoLongerAppliesSaysSo() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.group(id))
        let plan = try XCTUnwrap(groups.group(id)?.plan)
        // A trip between two stops that aren't next to each other.
        let leg = TravelLeg(fromStopID: plan.stops[0].id, toStopID: plan.stops[2].id, mode: .drive, minutes: 10, miles: 2)

        context.chooseTravel(PlanditStore.TravelOption(leg: leg, isLive: false))

        XCTAssertEqual(messages.current?.text, "Someone moved those stops, so your trip change wasn't made.")
        XCTAssertEqual(groups.group(id)?.pendingEdits, 0)
    }

    /// Saved's "Add to Maya's plan" while her plan is shown in Today (GE-3).
    func testAddingASavedPlaceGoesToThePlanShown() async throws {
        let id = await mayasGroup()
        let context = context()
        context.select(.group(id))
        let post = try XCTUnwrap(store.saved.first { $0.isMappable && !store.isInToday($0) })
        let ownBefore = store.today
        XCTAssertEqual(context.planName, "Maya's plan")
        XCTAssertFalse(context.contains(post))

        let added = try XCTUnwrap(context.add(post))

        XCTAssertTrue(context.contains(post))
        XCTAssertEqual(groups.group(id)?.plan?.stop(id: added)?.sourcePostID, post.id)
        XCTAssertEqual(store.today, ownBefore, "your own plan is untouched")
        XCTAssertNil(context.add(post), "already in it")

        context.select(.mine)
        XCTAssertEqual(context.planName, "today's plan")
        XCTAssertFalse(context.contains(post))
        XCTAssertNotNil(context.add(post))
        XCTAssertTrue(store.isInToday(post))
    }

    func testStartingAGroupPlanSelectsItAndGivesItsLink() async throws {
        let context = context()
        let ownBefore = store.today

        let link = try await context.startGroup().get()

        XCTAssertTrue(link.absoluteString.hasPrefix("https://plandit.app/j/"), link.absoluteString)
        let id = try XCTUnwrap(groups.groups.first?.id)
        XCTAssertEqual(router.todayChoice, .group(id))
        XCTAssertEqual(store.today, ownBefore)
    }

    // MARK: - Sheets keep the plan they opened on

    /// The review's probe: Edit plan opened on a group made with "Edit with friends" (so its stops
    /// have your plan's ids), the group ends before Save. Nothing changes, your plan least of all.
    func testASaveForAGroupThatHasGoneLeavesYourPlanAlone() async throws {
        let context = context()
        _ = try await context.startGroup().get()
        let id = try XCTUnwrap(router.todayChoice?.groupID)
        let sheet = context.pinned()
        let base = sheet.plan
        XCTAssertTrue(sheet.isGroup)
        let order = Array(base.stops[base.firstMovableIndex...].map(\.id).dropLast())
        let ownBefore = store.today
        _ = try await server.end(id)
        await groups.refresh(id)
        XCTAssertNil(groups.group(id))

        sheet.reorder(order, from: base)

        XCTAssertEqual(store.today.stops.count, ownBefore.stops.count, "your own plan keeps its stops")
        XCTAssertEqual(store.today, ownBefore)
        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(messages.current?.text, GroupPlanStore.text(for: .groupGone))
        XCTAssertFalse(sheet.canEdit)
        XCTAssertTrue(sheet.plan.stops.isEmpty, "the sheet shows nothing to change")

        // Today itself, in the moment before it goes back to your plan: still not your plan.
        context.reorder(order, from: base)
        XCTAssertEqual(store.today, ownBefore)
    }

    /// A sheet keeps editing the plan it opened on when Today switches meanwhile (a group joined by
    /// link while it's open).
    func testASheetKeepsEditingThePlanItOpenedOn() async throws {
        let maya = await mayasGroup()
        let jordan = await group(by: "Jordan")
        let context = context()
        context.select(.group(maya))
        let sheet = context.pinned()
        let stop = try XCTUnwrap(sheet.plan.stops.last?.id)

        router.todayChoice = .group(jordan)
        sheet.remove(stop)

        XCTAssertNil(groups.group(maya)?.plan?.stop(id: stop), "gone from Maya's plan")
        XCTAssertEqual(groups.group(jordan)?.plan?.stops.count, SampleData.dayPlan.stops.count, "Jordan's plan untouched")
        XCTAssertEqual(context.choice, .group(jordan), "Today itself follows the switch")
    }

    /// "Edit with friends" tapped twice before the first tap is done: one group plan, one create.
    func testTwoTapsMakeOneGroupPlan() async throws {
        let starter = GroupStarter()
        let context = context()
        async let first = starter.start(with: context)
        async let second = starter.start(with: context)
        let links = await [first, second]
        XCTAssertEqual(links.compactMap { $0 }.count, 1, "the second tap does nothing")
        XCTAssertEqual(groups.groups.count, 1)
        let created = await server.count(.create)
        XCTAssertEqual(created, 1)
        XCTAssertFalse(starter.isStarting)
    }
}
