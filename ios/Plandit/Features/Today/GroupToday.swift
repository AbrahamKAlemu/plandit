import Foundation

/// Which plan Today shows: the person's own, or one of their group plans.
enum TodayChoice: Hashable {
    case mine
    case group(UUID)

    var groupID: UUID? {
        if case .group(let id) = self { id } else { nil }
    }
}

/// Today with group plans (mode 3, "edit together"): which plans the switcher offers and what
/// each is called, what's turned off while a group plan is shown, and how Today's actions become
/// `PlanEdit`s. The views ask; nothing here touches a store.
enum GroupToday {
    /// One choice in the switcher: "Mine", "Maya's plan".
    struct Option: Identifiable, Equatable {
        var choice: TodayChoice
        var label: String
        var id: TodayChoice { choice }
    }

    /// What Today offers for the plan on screen. A group plan has no Undo, no budget or extras,
    /// no title edits, none of mode 1's sharing, and no suggestions.
    struct Controls: Equatable {
        var undo: Bool
        var budgetAndExtras: Bool
        var title: Bool
        /// Mode 1: friends' answers to a shared plan, and the swaps they marked.
        var shareAnswers: Bool
        var suggestions: Bool
        var askFriends: Bool
        /// "Share plan with friends" (a `/p/` page or a text).
        var sendPlan: Bool
        /// Stops can be moved, removed, checked off and retimed.
        var editing: Bool
        /// "Edit with friends" on your own plan.
        var startGroup: Bool
    }

    /// Something done on Today, before it becomes edits.
    enum Action: Equatable {
        case remove(UUID)
        /// The Edit plan sheet's answer, with the plan as the sheet opened, so a stop someone else
        /// added meanwhile is never taken out.
        case reorder([UUID], base: DayPlan)
        case status(PlanEdit.StatusAction, UUID)
        /// One trip, or every trip still ahead ("Drive everywhere").
        case travel([TravelLeg])
        case setTime(stopID: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool)
        case markOverdueDone
        case startRestFromNow
        case add(PlanCandidate)
    }

    /// The members sheet's and the start button's calls, for their error words.
    enum MemberAction: Equatable {
        case start, leave, remove(String), end, newLink
    }

    static let friendName = "Friend"
    static let mineLabel = "Mine"
    /// A group plan you organize.
    static let organizerLabel = "Group plan"
    static let dayOverLine = "This plan's day is over, so it can't be changed."
    static let loadingLine = "The plan is still loading. Try again in a moment."

    // MARK: - Names

    /// A member as Today shows them: the first word of their name, or "Friend".
    static func firstName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? friendName
    }

    /// One letter, for the circles in Today's header.
    static func initials(_ name: String) -> String {
        String(firstName(name).prefix(1)).uppercased()
    }

    // MARK: - The switcher

    /// The group plans Today offers on `today` (`YYYY-MM-DD`): today's, last night's until its
    /// day is over at 4 AM, and the one selected whatever its day.
    static func shown(_ groups: [GroupPlanState], today: String, keeping selected: UUID?) -> [GroupPlanState] {
        groups.filter { $0.id == selected || $0.date == today || ($0.date < today && !$0.isDayOver) }
    }

    /// "Mine", then each group plan; nothing when there are none.
    static func options(groups: [GroupPlanState]) -> [Option] {
        guard !groups.isEmpty else { return [] }
        var seen: [String: Int] = [:]
        let named = groups.map { group -> Option in
            let base = label(for: group)
            seen[base, default: 0] += 1
            let count = seen[base] ?? 1
            return Option(choice: .group(group.id), label: count == 1 ? base : "\(base) \(count)")
        }
        return [Option(choice: .mine, label: mineLabel)] + named
    }

    /// "Maya's plan", or "Group plan" for one you organize.
    static func label(for group: GroupPlanState) -> String {
        group.isOrganizer ? organizerLabel : "\(firstName(group.organizerName))'s plan"
    }

    /// The plan Today shows: the one picked while it's still offered; otherwise your own when it
    /// has stops, or else the first group plan.
    static func resolve(_ choice: TodayChoice?, groups: [GroupPlanState], ownPlanHasStops: Bool) -> TodayChoice {
        switch choice {
        case .mine?:
            return .mine
        case .group(let id)? where groups.contains(where: { $0.id == id }):
            return .group(id)
        default:
            if ownPlanHasStops { return .mine }
            return groups.first.map { .group($0.id) } ?? .mine
        }
    }

    // MARK: - What's turned off

    static func controls(for group: GroupPlanState?, groupsAvailable: Bool) -> Controls {
        guard let group else {
            return Controls(undo: true, budgetAndExtras: true, title: true, shareAnswers: true, suggestions: true, askFriends: true,
                            sendPlan: true, editing: true, startGroup: groupsAvailable)
        }
        return Controls(undo: false, budgetAndExtras: false, title: false, shareAnswers: false, suggestions: false, askFriends: false,
                        sendPlan: false, editing: group.plan != nil && !group.isDayOver && !group.isReadOnly, startGroup: false)
    }

    /// A group plan that went away while a sheet was open on it: nothing left to change.
    static let goneControls = Controls(undo: false, budgetAndExtras: false, title: false, shareAnswers: false, suggestions: false,
                                       askFriends: false, sendPlan: false, editing: false, startGroup: false)

    /// Why a group plan can't be changed, shown above it.
    static func lockedLine(_ group: GroupPlanState) -> String? {
        if group.isDayOver { return dayOverLine }
        if group.isReadOnly { return GroupPlanStore.text(for: .readOnly) }
        return nil
    }

    // MARK: - Actions as edits

    /// The edits for an action on `plan` (the group plan as shown). Each names stops by id.
    static func edits(for action: Action, in plan: DayPlan, travel: TravelPreference, now: Date, calendar: Calendar) -> [PlanEdit] {
        switch action {
        case .remove(let id):
            return PlanEdit.removing(id, in: plan, travel: travel).map { [$0] } ?? []
        case let .reorder(ids, base):
            return PlanEdit.reordering(ids, in: base, travel: travel)
        case let .status(action, id):
            return PlanEdit.status(action, stopID: id, in: plan).map { [$0] } ?? []
        case .travel(let legs):
            return legs.map(PlanEdit.travel)
        case let .setTime(id, start, minutes, moveLaterStops):
            return [.setTime(stopID: id, start: start, durationMinutes: minutes, moveLaterStops: moveLaterStops)]
        case .markOverdueDone:
            return [.markOverdueDone]
        case .startRestFromNow:
            return [.startRestFromNow]
        case .add(let candidate):
            return [PlanEdit.adding(candidate, to: plan, travel: travel, now: now, calendar: calendar)]
        }
    }

    /// The plan with these edits made, skipping any that no longer apply: what a sheet previews.
    static func preview(_ edits: [PlanEdit], on plan: DayPlan, now: Date, calendar: Calendar) -> DayPlan {
        edits.reduce(plan) { result, edit in
            if case .applied(let next) = PlanEdit.apply(edit, to: result, now: now, calendar: calendar) { return next }
            return result
        }
    }

    // MARK: - What the person hears

    /// Words for edits that weren't made: nil when every one was made or already shown.
    static func message(for results: [GroupEditResult], group: GroupPlanState?) -> String? {
        let reasons = results.compactMap { result -> PlanEdit.Reason? in
            if case .noLongerApplies(let reason) = result { return reason }
            return nil
        }
        if let first = reasons.first {
            return GroupPlanStore.text(for: .editsNotMade(count: reasons.count, author: nil, reason: first))
        }
        guard results.contains(.unavailable) else { return nil }
        guard let group else { return GroupPlanStore.text(for: .groupGone) }
        if let locked = lockedLine(group) { return locked }
        if group.plan == nil { return loadingLine }
        return GroupPlanStore.text(for: .editRefused(nil))
    }

    /// A failed start, leave, remove, end or new link, in plain words.
    static func failureText(_ failure: GroupPlanFailure, for action: MemberAction) -> String {
        switch failure {
        case .offline: return "You're offline. Try again when you're connected."
        case .gone: return GroupPlanStore.text(for: .groupGone)
        case .refused(let detail?): return detail
        case .tooLarge(let detail): return detail ?? "This plan is too big to share. Remove a stop and try again."
        case .unreadable: return "This version of Plandit can't do that. Update the app and try again."
        case .refused(nil), .failed:
            switch action {
            case .start: return "The group plan couldn't be started. Try again."
            case .leave: return "You couldn't leave the plan. Try again."
            case .remove(let name): return "\(firstName(name)) couldn't be removed. Try again."
            case .end: return "The plan couldn't be ended. Try again."
            case .newLink: return "A new link couldn't be made. Try again."
            }
        }
    }
}
