import XCTest
@testable import Plandit

/// Which day "Build our plan" plans: a later day is previewed on its own day (persona P1) but only
/// built on that day (D1), and "today" means today on the phone too, as Today does (review R9).
@MainActor final class GroupPlanDayTests: XCTestCase {
    private typealias F = AskFriendsFixtures

    override func setUp() {
        super.setUp()
        PlanditStore.requestRefreshInterval = 10
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    // P1
    func testALaterDayIsPreviewedOnItsOwnDayButNotBuilt() async throws {
        let later = Calendar.current.date(byAdding: .day, value: 2, to: F.elevenAM)!
        let (store, requests) = try await F.requestedStore(on: later)
        await requests.setAnswers([F.answer("Maya", budget: 20, 13, 18, stars: [SampleData.tacosPost.id])])
        await store.refreshPlanRequest(force: true)
        let plan = try XCTUnwrap(F.plan(store))

        let preview = try XCTUnwrap(store.previewGroupPlan(plan, now: F.elevenAM), "the plan as it looks with the answers so far")
        let first = try XCTUnwrap(preview.stops.first)
        XCTAssertTrue(Calendar.current.isDate(first.start, inSameDayAs: later), "planned on the link's day")
        XCTAssertGreaterThanOrEqual(first.start, ClockTime(13).date(on: later)!)
        XCTAssertLessThanOrEqual(preview.end ?? .distantFuture, ClockTime(18).date(on: later)!)
        XCTAssertTrue(preview.stops.contains { $0.sourcePostID == SampleData.tacosPost.id })

        let before = store.today.stops.map(\.id)
        XCTAssertFalse(store.canBuildGroupPlan(now: F.elevenAM))
        XCTAssertNil(store.buildGroupPlan(plan, now: F.elevenAM), "Build our plan waits for the day")
        XCTAssertEqual(store.today.stops.map(\.id), before)
        XCTAssertTrue(store.canBuildGroupPlan(now: Calendar.current.date(byAdding: .day, value: 2, to: F.elevenAM)!))
    }

    // P1
    func testTheLaterDayLineSaysHowThePlanLooks() throws {
        let link = PlanRequestLink(slug: "req1", url: URL(string: "https://plandit.app/g/req1")!, day: "2026-11-24",
                                   windowStart: "12:00", windowEnd: "20:00", timeZone: "America/New_York",
                                   answersBy: Date(), placeIDs: [], builtPlanID: nil)
        let now = calendar("America/New_York").date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 11))!
        XCTAssertEqual(AskFriendsText.laterDay(link, now: now),
                       "This is how the plan looks with the answers so far. You can build it on Tuesday, November 24.")
    }

    // R9
    func testBuildWaitsUntilItsTodayOnThePhoneToo() async throws {
        let now = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!
        guard let zone = ["Pacific/Kiritimati", "Pacific/Pago_Pago"].first(where: {
            DayPlan.isoDay(now, calendar: calendar($0)) != DayPlan.isoDay(now, calendar: .current)
        }) else { throw XCTSkip("the phone's day is the same everywhere tried") }
        let store = F.makeStore()
        store.requestClient = RecordingRequests()
        let draft = PlanRequestDraft(posts: F.places, day: now, start: ClockTime(0), end: ClockTime(23, 45),
                                     answersBy: now.addingTimeInterval(60), calendar: calendar(zone))
        try await store.createPlanRequest(draft, answersBy: now.addingTimeInterval(60))
        let link = try XCTUnwrap(store.planRequest)
        XCTAssertTrue(link.isToday(now: now), "today where the link was made")
        XCTAssertFalse(store.canBuildGroupPlan(now: now), "but not today on the phone")
        let plan = try XCTUnwrap(F.plan(store))
        let before = store.today.stops.map(\.id)
        XCTAssertNil(store.buildGroupPlan(plan, now: now))
        XCTAssertEqual(store.today.stops.map(\.id), before)
    }

    // R9
    func testTheDayIsWrittenInTheLinksTimeZone() throws {
        guard TimeZone.current.secondsFromGMT() < 12 * 3600 else { throw XCTSkip("the phone is already that far east") }
        let link = PlanRequestLink(slug: "req1", url: URL(string: "https://plandit.app/g/req1")!, day: "2026-11-24",
                                   windowStart: "12:00", windowEnd: "20:00", timeZone: "Pacific/Kiritimati",
                                   answersBy: Date(), placeIDs: [], builtPlanID: nil)
        let now = calendar("America/New_York").date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 11))!
        XCTAssertEqual(AskFriendsText.day(link, now: now), "Tuesday, November 24")
    }
}
