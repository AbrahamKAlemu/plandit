import XCTest
@testable import Plandit

/// Today with group plans (mode 3, G3b-2): which plans the switcher offers and what they're called,
/// what's turned off while a group plan is shown, how Today's actions become `PlanEdit`s, and the
/// words for edits that weren't made.
@MainActor final class GroupTodayTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: hour, minute: minute))!
    }

    /// The sample day as a group plan: its own stop ids, every stop still ahead.
    private func day() -> DayPlan {
        var plan = SampleData.dayPlan.withFreshStopIDs()
        for index in plan.stops.indices { plan.stops[index].status = .upcoming }
        return plan
    }

    private func group(_ organizer: String = "Maya", date: String = "2026-11-20", isOrganizer: Bool = false, plan: DayPlan? = nil,
                       dayOver: Bool = false, readOnly: Bool = false, pending: Int = 0) -> GroupPlanState {
        GroupPlanState(id: UUID(), date: date, plan: plan ?? day(), version: 1,
                       members: [GroupPlanMember(id: UUID(), name: organizer, isOrganizer: true)],
                       memberId: UUID(), isOrganizer: isOrganizer, organizerName: organizer, memberCount: 3,
                       inviteUrl: nil, pendingEdits: pending, isReadOnly: readOnly, isDayOver: dayOver)
    }

    // MARK: - Names

    func testMembersShowAsAFirstNameAndOneInitial() {
        XCTAssertEqual(GroupToday.firstName("Maya Lopez"), "Maya")
        XCTAssertEqual(GroupToday.firstName("  Jordan "), "Jordan")
        XCTAssertEqual(GroupToday.firstName(""), "Friend")
        XCTAssertEqual(GroupToday.firstName("   "), "Friend")
        XCTAssertEqual(GroupToday.initials("maya"), "M")
        XCTAssertEqual(GroupToday.initials(""), "F")
    }

    // MARK: - The switcher

    func testSwitcherOffersMineAndEachGroupForTheDay() {
        let maya = group("Maya")
        let mine = group("Sofia", isOrganizer: true)
        let shown = GroupToday.shown([maya, mine], today: "2026-11-20", keeping: nil)
        XCTAssertEqual(shown.map(\.id), [maya.id, mine.id])
        XCTAssertEqual(GroupToday.options(groups: shown).map(\.label), ["Mine", "Maya's plan", "Group plan"])
        XCTAssertEqual(GroupToday.options(groups: shown).map(\.choice), [.mine, .group(maya.id), .group(mine.id)])
    }

    func testNoSwitcherWithoutGroupPlans() {
        XCTAssertEqual(GroupToday.options(groups: []), [])
    }

    func testTwoPlansFromTheSameOrganizerAreNumbered() {
        let first = group("Maya")
        let second = group("Maya Lopez")
        XCTAssertEqual(GroupToday.options(groups: [first, second]).map(\.label), ["Mine", "Maya's plan", "Maya's plan 2"])
    }

    func testAnOrganizerWithNoNameIsAFriend() {
        XCTAssertEqual(GroupToday.options(groups: [group("")]).map(\.label), ["Mine", "Friend's plan"])
    }

    func testLastNightsPlanStaysUntilItsDayIsOver() {
        let lastNight = group(date: "2026-11-19")
        let over = group(date: "2026-11-19", dayOver: true)
        let tomorrow = group(date: "2026-11-21")
        XCTAssertEqual(GroupToday.shown([lastNight, over, tomorrow], today: "2026-11-20", keeping: nil).map(\.id), [lastNight.id])
    }

    func testTheSelectedPlanIsKeptWhateverItsDay() {
        let over = group(date: "2026-11-19", dayOver: true)
        let tomorrow = group(date: "2026-11-21")
        XCTAssertEqual(GroupToday.shown([over, tomorrow], today: "2026-11-20", keeping: over.id).map(\.id), [over.id])
        XCTAssertEqual(GroupToday.shown([over, tomorrow], today: "2026-11-20", keeping: tomorrow.id).map(\.id), [tomorrow.id])
    }

    func testWhichPlanTodayShows() {
        let maya = group()
        let jordan = group("Jordan")
        XCTAssertEqual(GroupToday.resolve(nil, groups: [maya, jordan], ownPlanHasStops: true), .mine, "your own plan first")
        XCTAssertEqual(GroupToday.resolve(nil, groups: [maya, jordan], ownPlanHasStops: false), .group(maya.id), "nothing of your own: the first group")
        XCTAssertEqual(GroupToday.resolve(nil, groups: [], ownPlanHasStops: false), .mine)
        XCTAssertEqual(GroupToday.resolve(.mine, groups: [maya], ownPlanHasStops: false), .mine, "picked")
        XCTAssertEqual(GroupToday.resolve(.group(jordan.id), groups: [maya, jordan], ownPlanHasStops: true), .group(jordan.id))
        XCTAssertEqual(GroupToday.resolve(.group(UUID()), groups: [maya], ownPlanHasStops: true), .mine, "a group that's gone falls back")
        XCTAssertEqual(GroupToday.resolve(.group(UUID()), groups: [maya], ownPlanHasStops: false), .group(maya.id))
    }

    // MARK: - What's turned off

    func testOwnPlanKeepsEverything() {
        let controls = GroupToday.controls(for: nil, groupsAvailable: true)
        XCTAssertTrue(controls.undo)
        XCTAssertTrue(controls.budgetAndExtras)
        XCTAssertTrue(controls.title)
        XCTAssertTrue(controls.shareAnswers)
        XCTAssertTrue(controls.suggestions)
        XCTAssertTrue(controls.askFriends)
        XCTAssertTrue(controls.sendPlan)
        XCTAssertTrue(controls.editing)
        XCTAssertTrue(controls.startGroup)
        XCTAssertFalse(GroupToday.controls(for: nil, groupsAvailable: false).startGroup, "no group plans on this account")
    }

    func testGroupPlanTurnsOffWhatIsntShared() {
        let controls = GroupToday.controls(for: group(), groupsAvailable: true)
        XCTAssertFalse(controls.undo)
        XCTAssertFalse(controls.budgetAndExtras)
        XCTAssertFalse(controls.title)
        XCTAssertFalse(controls.shareAnswers)
        XCTAssertFalse(controls.suggestions)
        XCTAssertFalse(controls.askFriends)
        XCTAssertFalse(controls.sendPlan)
        XCTAssertFalse(controls.startGroup)
        XCTAssertTrue(controls.editing)
    }

    func testAPlanThatCantChangeSaysWhy() {
        XCTAssertFalse(GroupToday.controls(for: group(dayOver: true), groupsAvailable: true).editing)
        XCTAssertFalse(GroupToday.controls(for: group(readOnly: true), groupsAvailable: true).editing)
        XCTAssertEqual(GroupToday.lockedLine(group(dayOver: true)), GroupToday.dayOverLine)
        XCTAssertEqual(GroupToday.lockedLine(group(readOnly: true)), GroupPlanStore.text(for: .readOnly))
        XCTAssertNil(GroupToday.lockedLine(group()))
        var loading = group()
        loading.plan = nil
        XCTAssertFalse(GroupToday.controls(for: loading, groupsAvailable: true).editing, "nothing to edit yet")
    }

    // MARK: - Today's actions as edits

    func testRemoveIsOneRemoveEdit() {
        let plan = day()
        let met = plan.stops[1]
        XCTAssertEqual(GroupToday.edits(for: .remove(met.id), in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar),
                       [.remove(stopID: met.id, status: .upcoming, travel: .walkAndTransit)])
        XCTAssertEqual(GroupToday.edits(for: .remove(UUID()), in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar), [])
    }

    func testArriveCompleteAndLeaveAreStatusEdits() {
        let plan = day()
        let met = plan.stops[1].id
        for action in [PlanEdit.StatusAction.arrive, .complete, .leave] {
            XCTAssertEqual(GroupToday.edits(for: .status(action, met), in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar),
                           [PlanEdit.status(action, stopID: met, in: plan)!])
        }
    }

    /// Someone added a stop while the Edit sheet was open: saving the new order keeps it.
    func testReorderKeepsAStopSomeoneElseAdded() throws {
        let base = day()
        let ids = base.stops.map(\.id)
        let added = PlanStop(place: SampleData.met, start: at(19), durationMinutes: 30, estimatedCost: 0, status: .upcoming)
        var current = base
        current.stops.append(added)
        let order = [ids[0], ids[2], ids[1], ids[3], ids[5]]

        let edits = GroupToday.edits(for: .reorder(order, base: base), in: current, travel: .walkAndTransit, now: at(9), calendar: calendar)
        XCTAssertFalse(edits.contains(.remove(stopID: added.id, status: .upcoming, travel: .walkAndTransit)))
        XCTAssertTrue(edits.contains(.remove(stopID: ids[4], status: .upcoming, travel: .walkAndTransit)))

        let result = GroupToday.preview(edits, on: current, now: at(9), calendar: calendar)
        XCTAssertEqual(result.stops.map(\.id), order + [added.id])
    }

    func testTravelForTheRestOfTheDayIsOneEditPerTrip() {
        let plan = day()
        let legs = plan.legs.map { leg -> TravelLeg in
            var leg = leg
            leg.mode = .drive
            return leg
        }
        XCTAssertEqual(GroupToday.edits(for: .travel(legs), in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar),
                       legs.map(PlanEdit.travel))
    }

    func testTimeCatchUpAndAddAreTheirOwnEdits() {
        let plan = day()
        let met = plan.stops[1].id
        XCTAssertEqual(GroupToday.edits(for: .setTime(stopID: met, start: at(12), durationMinutes: 60, moveLaterStops: true),
                                        in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar),
                       [.setTime(stopID: met, start: at(12), durationMinutes: 60, moveLaterStops: true)])
        XCTAssertEqual(GroupToday.edits(for: .markOverdueDone, in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar), [.markOverdueDone])
        XCTAssertEqual(GroupToday.edits(for: .startRestFromNow, in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar), [.startRestFromNow])

        let candidate = PlanCandidate(post: SampleData.savedPosts.first { $0.isMappable && $0.place?.name != nil }!)!
        XCTAssertEqual(GroupToday.edits(for: .add(candidate), in: plan, travel: .walkAndTransit, now: at(9), calendar: calendar),
                       [PlanEdit.adding(candidate, to: plan, travel: .walkAndTransit, now: at(9), calendar: calendar)])
    }

    // MARK: - What the person hears

    func testOnlyEditsThatWerentMadeGetAMessage() {
        XCTAssertNil(GroupToday.message(for: [.queued], group: group()))
        XCTAssertNil(GroupToday.message(for: [.alreadyApplied, .queued], group: group()))
        XCTAssertNil(GroupToday.message(for: [], group: group()))
        let stop = UUID()
        XCTAssertEqual(GroupToday.message(for: [.queued, .noLongerApplies(.stopGone(stop))], group: group()),
                       "Someone removed that stop, so your change wasn't made.")
        XCTAssertEqual(GroupToday.message(for: [.noLongerApplies(.stopGone(stop)), .noLongerApplies(.stopChanged(stop))], group: group()),
                       "Someone changed the plan first, so 2 of your changes weren't made.")
    }

    func testUnavailableSaysWhy() {
        XCTAssertEqual(GroupToday.message(for: [.unavailable], group: nil), GroupPlanStore.text(for: .groupGone))
        XCTAssertEqual(GroupToday.message(for: [.unavailable], group: group(dayOver: true)), GroupToday.dayOverLine)
        XCTAssertEqual(GroupToday.message(for: [.unavailable], group: group(readOnly: true)), GroupPlanStore.text(for: .readOnly))
        var loading = group()
        loading.plan = nil
        XCTAssertEqual(GroupToday.message(for: [.unavailable], group: loading), GroupToday.loadingLine)
    }

    func testFailuresInPlainWords() {
        XCTAssertEqual(GroupToday.failureText(.offline, for: .end), "You're offline. Try again when you're connected.")
        XCTAssertEqual(GroupToday.failureText(.gone, for: .leave), GroupPlanStore.text(for: .groupGone))
        XCTAssertEqual(GroupToday.failureText(.refused("Only the organizer can do that."), for: .newLink), "Only the organizer can do that.")
        XCTAssertEqual(GroupToday.failureText(.refused(nil), for: .remove("Jordan")), "Jordan couldn't be removed. Try again.")
        XCTAssertEqual(GroupToday.failureText(.failed, for: .start), "The group plan couldn't be started. Try again.")
        XCTAssertEqual(GroupToday.failureText(.failed, for: .end), "The plan couldn't be ended. Try again.")
        XCTAssertEqual(GroupToday.failureText(.failed, for: .leave), "You couldn't leave the plan. Try again.")
        XCTAssertEqual(GroupToday.failureText(.failed, for: .newLink), "A new link couldn't be made. Try again.")
        XCTAssertEqual(GroupToday.failureText(.tooLarge(nil), for: .start), "This plan is too big to share. Remove a stop and try again.")
        XCTAssertEqual(GroupToday.failureText(.unreadable, for: .start), "This version of Plandit can't do that. Update the app and try again.")
    }

    /// The link's page can't show the plan, so the message sends friends to the app.
    func testTheInviteMessageSaysToOpenItInTheApp() {
        XCTAssertEqual(GroupMembersText.shareMessage,
                       "Let's plan today together. Open this in the Plandit app to see the plan and change it with me.")
    }
}

/// The banner's messages: one at a time, in order, no repeats back to back.
@MainActor final class GroupMessagesTests: XCTestCase {
    func testMessagesShowOneAtATimeInOrder() {
        let messages = GroupMessages()
        XCTAssertNil(messages.current)
        messages.post("First")
        messages.post("Second")
        XCTAssertEqual(messages.current?.text, "First")
        messages.dismiss(messages.current!.id)
        XCTAssertEqual(messages.current?.text, "Second")
        messages.dismiss(messages.current!.id)
        XCTAssertNil(messages.current)
    }

    func testTheSameMessageTwiceInARowShowsOnce() {
        let messages = GroupMessages()
        messages.post("Maya removed that stop, so your change wasn't made.")
        messages.post("Maya removed that stop, so your change wasn't made.")
        messages.dismiss(messages.current!.id)
        XCTAssertNil(messages.current)
    }

    func testDismissingAnOldMessageLeavesTheCurrentOne() {
        let messages = GroupMessages()
        messages.post("First")
        let first = messages.current!.id
        messages.dismiss(first)
        messages.post("Second")
        messages.dismiss(first)
        XCTAssertEqual(messages.current?.text, "Second")
    }

    func testTheStoresMessagesArePosted() {
        let messages = GroupMessages()
        let groups = GroupPlanStore(userID: "messages-\(UUID().uuidString)", server: FakeGroupPlanServer(),
                                    directory: FileManager.default.temporaryDirectory)
        defer { groups.close() }
        messages.listen(to: groups)
        groups.onMessage?(GroupPlanMessage(groupID: UUID(), kind: .groupGone, text: "This group plan ended, or you're no longer in it."))
        XCTAssertEqual(messages.current?.text, "This group plan ended, or you're no longer in it.")
    }
}

/// Opening a group plan from elsewhere (a join link), and landing on your own plan after building one.
@MainActor final class GroupPlanRoutingTests: XCTestCase {
    func testOpeningAGroupPlanShowsTodayWithItSelected() {
        let router = SheetRouter()
        router.tab = .saved
        router.todayPath = [UUID()]
        let id = UUID()
        router.groupPlanToOpen = id
        router.openRequestedGroupPlan()
        XCTAssertEqual(router.tab, .today)
        XCTAssertEqual(router.todayChoice, .group(id))
        XCTAssertEqual(router.todayPath, [])
        XCTAssertNil(router.groupPlanToOpen)
    }

    /// The join sheet's hand-off (`openGroupPlan`) is what Today takes: the group joined, selected.
    func testAGroupJustJoinedIsSelectedInToday() {
        let router = SheetRouter()
        router.tab = .saved
        router.inviteToJoin = GroupInvite(token: "fake-invite-for-tests")
        let id = UUID()
        router.openGroupPlan(id)
        router.openRequestedGroupPlan()
        XCTAssertNil(router.inviteToJoin)
        XCTAssertEqual(router.tab, .today)
        XCTAssertEqual(router.todayChoice, .group(id))
        XCTAssertNil(router.groupPlanToOpen)
    }

    func testNothingToOpenChangesNothing() {
        let router = SheetRouter()
        router.tab = .saved
        router.openRequestedGroupPlan()
        XCTAssertEqual(router.tab, .saved)
        XCTAssertNil(router.todayChoice)
    }

    func testAPlanJustBuiltShowsYourOwn() {
        let router = SheetRouter()
        router.todayChoice = .group(UUID())
        router.finishPlanning()
        XCTAssertEqual(router.todayChoice, .mine)
    }
}
