import SwiftUI

/// The plan Today shows and the actions on it. Your own plan goes through `PlanditStore`, with
/// Undo; a group plan through `GroupPlanStore.apply`, as edits that name stops by id. Never both:
/// a group edit leaves your own plan alone and the other way round (SW-1, SW-2).
struct TodayPlanContext {
    let store: PlanditStore
    let groups: GroupPlanStore?
    let router: SheetRouter
    let messages: GroupMessages?
    var now: Date = AppClock.now
    var calendar: Calendar = .current
    /// Set by `pinned()`: the plan this context edits, whatever the switcher says later.
    var pin: TodayChoice?

    /// This context, kept on the plan shown now: for a sheet or a stop's screen, which must keep
    /// editing the plan it was opened on.
    func pinned() -> TodayPlanContext {
        var copy = self
        copy.pin = choice
        return copy
    }

    // MARK: - What's shown

    /// Group plans the switcher offers right now.
    var offered: [GroupPlanState] {
        guard let groups else { return [] }
        return GroupToday.shown(groups.groups, today: GroupPlanDay.string(for: now, calendar: calendar),
                                keeping: router.todayChoice?.groupID)
    }

    var options: [GroupToday.Option] { GroupToday.options(groups: offered) }

    var choice: TodayChoice {
        pin ?? GroupToday.resolve(router.todayChoice, groups: offered, ownPlanHasStops: !store.today.stops.isEmpty)
    }

    /// The group plan on screen; nil for your own plan, or for a pinned group plan that has gone.
    var group: GroupPlanState? {
        guard let id = choice.groupID else { return nil }
        return groups?.group(id)
    }

    var isGroup: Bool { choice.groupID != nil }

    /// What the timeline shows. A group plan not fetched yet, or gone, shows as an empty day.
    var plan: DayPlan {
        guard isGroup else { return store.today }
        return group?.plan ?? DayPlan(date: now, title: "", budget: 0, stops: [], legs: [])
    }

    var controls: GroupToday.Controls {
        if isGroup, group == nil { return GroupToday.goneControls }
        return GroupToday.controls(for: group, groupsAvailable: groups != nil)
    }

    var canEdit: Bool { controls.editing }

    /// "Maya's plan", for the members sheet and messages.
    var label: String? {
        guard let group else { return nil }
        return options.first { $0.choice == .group(group.id) }?.label ?? GroupToday.label(for: group)
    }

    func select(_ choice: TodayChoice) {
        router.todayChoice = choice
        router.todayPath = []
    }

    // MARK: - Lookups in the plan shown

    func stop(id: UUID) -> PlanStop? { plan.stop(id: id) }

    func stopNumber(id: UUID) -> Int? { plan.stops.firstIndex { $0.id == id }.map { $0 + 1 } }

    func travelMode(into stopID: UUID) -> TravelMode {
        plan.legs.first { $0.toStopID == stopID }?.mode ?? .walk
    }

    func travelOptions(forLeg id: UUID) -> [PlanditStore.TravelOption] {
        store.travelOptions(forLeg: id, in: plan)
    }

    func loadTravelOptions(forLeg id: UUID) async {
        await store.loadTravelOptions(forLeg: id, in: plan)
    }

    // MARK: - Actions

    func remove(_ id: UUID) {
        perform(.remove(id)) { store.removeStop(id) }
    }

    func arrive(at id: UUID) {
        perform(.status(.arrive, id)) { store.arrive(at: id) }
    }

    func complete(_ id: UUID) {
        perform(.status(.complete, id)) { store.complete(id) }
    }

    func leave(_ id: UUID) {
        perform(.status(.leave, id)) { store.leave(id) }
    }

    /// The Edit plan sheet's order. `base` is the plan as the sheet opened.
    func reorder(_ ids: [UUID], from base: DayPlan) {
        perform(.reorder(ids, base: base)) { store.reorder(ids) }
    }

    func previewReorder(_ ids: [UUID], from base: DayPlan) -> DayPlan {
        guard isGroup else { return store.previewReorder(ids) }
        return preview(.reorder(ids, base: base))
    }

    func chooseTravel(_ option: PlanditStore.TravelOption) {
        perform(.travel([option.leg])) { store.chooseTravel(option) }
    }

    func previewTravel(_ option: PlanditStore.TravelOption) -> DayPlan {
        guard isGroup else { return store.previewTravel(option) }
        return preview(.travel([option.leg]))
    }

    func chooseTravelForRestOfDay(_ mode: TravelMode) {
        perform(.travel(store.restOfDayLegs(mode, in: plan))) { store.chooseTravelForRestOfDay(mode) }
    }

    func setTime(ofStop id: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool) {
        perform(.setTime(stopID: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops)) {
            store.setTime(ofStop: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops)
        }
    }

    func previewTime(ofStop id: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool) -> DayPlan {
        guard isGroup else { return store.previewTime(ofStop: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops) }
        return preview(.setTime(stopID: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops))
    }

    func markOverdueDone() {
        perform(.markOverdueDone) { store.markOverdueDone() }
    }

    func startRestFromNow() {
        perform(.startRestFromNow) { store.startRestFromNow() }
    }

    /// Where Saved's + puts a place: "today's plan", "Maya's plan", "your group plan".
    var planName: String {
        guard let group else { return "today's plan" }
        return group.isOrganizer ? "your group plan" : (label ?? GroupToday.label(for: group))
    }

    func contains(_ post: SavedPost) -> Bool {
        guard isGroup else { return store.isInToday(post) }
        return plan.stops.contains { $0.sourcePostID == post.id }
    }

    /// Adds a saved place to the plan shown in Today, where it fits best (GE-3 for a group plan).
    /// Returns the new stop's id, or nil when it wasn't added.
    @discardableResult
    func add(_ post: SavedPost) -> UUID? {
        guard let id = choice.groupID else { return store.addToToday(post.id) }
        guard canEdit, !contains(post), let candidate = PlanCandidate(post: post) else { return nil }
        return apply(.add(candidate), to: id).contains(.queued) ? candidate.id : nil
    }

    /// "Edit with friends": a group plan made from your own, selected, and its link to send.
    func startGroup() async -> Result<URL, GroupPlanFailure> {
        guard let groups else { return .failure(.failed) }
        switch await groups.create(from: store.today) {
        case .success(let id):
            select(.group(id))
            guard let link = groups.group(id)?.inviteUrl else { return .failure(.failed) }
            return .success(link)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    // MARK: - Routing

    private func perform(_ action: GroupToday.Action, mine: () -> Void) {
        guard let id = target.groupID else {
            mine()
            return
        }
        apply(action, to: id)
    }

    /// Where an edit goes: the plan this context was pinned to, or else the group plan picked in
    /// the switcher, even one that has just gone. An edit meant for a group plan is refused then,
    /// with the reason, and never lands on your own plan (whose stop ids a group made with "Edit
    /// with friends" shares).
    private var target: TodayChoice {
        if let pin { return pin }
        if groups != nil, let picked = router.todayChoice?.groupID { return .group(picked) }
        return choice
    }

    /// Makes the action's edits on the group plan, and says so when one couldn't be made.
    @discardableResult
    private func apply(_ action: GroupToday.Action, to id: UUID) -> [GroupEditResult] {
        guard let groups else { return [] }
        let results: [GroupEditResult]
        if let plan = groups.group(id)?.plan {
            let edits = GroupToday.edits(for: action, in: plan, travel: store.travelPreference, now: now, calendar: calendar)
            results = edits.map { groups.apply($0, to: id) }
        } else {
            results = [.unavailable]
        }
        if let text = GroupToday.message(for: results, group: groups.group(id)) {
            messages?.post(text)
        }
        return results
    }

    private func preview(_ action: GroupToday.Action) -> DayPlan {
        let edits = GroupToday.edits(for: action, in: plan, travel: store.travelPreference, now: now, calendar: calendar)
        return GroupToday.preview(edits, on: plan, now: now, calendar: calendar)
    }
}

/// Today's plan context for a view, from the environment.
@propertyWrapper
struct TodayContext: DynamicProperty {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    @Environment(GroupPlanStore.self) private var groups: GroupPlanStore?
    @Environment(GroupMessages.self) private var messages: GroupMessages?
    /// The plan a pinned view opened on, kept for as long as the view is on screen.
    @State private var pin = Pin()
    private let isPinned: Bool

    /// `pinned`: for a sheet or a stop's screen, which keeps editing the plan it opened on even if
    /// that group goes away or Today switches meanwhile. Today itself follows the switcher.
    init(pinned: Bool = false) {
        isPinned = pinned
    }

    var wrappedValue: TodayPlanContext {
        let context = TodayPlanContext(store: store, groups: groups, router: router, messages: messages)
        guard isPinned else { return context }
        // Not observed: noting the choice once doesn't redraw anything.
        if pin.choice == nil { pin.choice = context.choice }
        var pinned = context
        pinned.pin = pin.choice
        return pinned
    }

    private final class Pin {
        var choice: TodayChoice?
    }
}
