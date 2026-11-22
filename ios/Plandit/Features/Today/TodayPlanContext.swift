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

    // MARK: - What's shown

    /// Group plans the switcher offers right now.
    var offered: [GroupPlanState] {
        guard let groups else { return [] }
        return GroupToday.shown(groups.groups, today: GroupPlanDay.string(for: now, calendar: calendar),
                                keeping: router.todayChoice?.groupID)
    }

    var options: [GroupToday.Option] { GroupToday.options(groups: offered) }

    var choice: TodayChoice {
        GroupToday.resolve(router.todayChoice, groups: offered, ownPlanHasStops: !store.today.stops.isEmpty)
    }

    /// The group plan on screen; nil for your own plan.
    var group: GroupPlanState? {
        guard let id = choice.groupID else { return nil }
        return offered.first { $0.id == id }
    }

    var isGroup: Bool { group != nil }

    /// What the timeline shows. A group plan not fetched yet shows as an empty day.
    var plan: DayPlan {
        guard let group else { return store.today }
        return group.plan ?? DayPlan(date: now, title: "", budget: 0, stops: [], legs: [])
    }

    var controls: GroupToday.Controls { GroupToday.controls(for: group, groupsAvailable: groups != nil) }

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

    /// Adds a saved place to the group plan on screen. Your own plan uses `PlanditStore.addToToday`.
    func addToGroup(_ candidate: PlanCandidate) {
        guard let id = group?.id else { return }
        apply(.add(candidate), to: id)
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
        guard let id = choice.groupID else {
            mine()
            return
        }
        apply(action, to: id)
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

    var wrappedValue: TodayPlanContext {
        TodayPlanContext(store: store, groups: groups, router: router, messages: messages)
    }
}
