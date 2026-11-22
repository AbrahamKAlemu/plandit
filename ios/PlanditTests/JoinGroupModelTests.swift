import XCTest
@testable import Plandit

/// The join sheet's states (GE-2, JN-2, JN-3) against `FakeGroupPlanServer`: the preview, joining,
/// no answer, a link that doesn't work, joining twice, the organizer's own link, and an account
/// without group plans. And the words it shows.
@MainActor final class JoinGroupModelTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private var directory: URL!
    private var server: FakeGroupPlanServer!
    private var stores: [GroupPlanStore] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "join-group-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = FakeGroupPlanServer(yourName: "Sofia")
        stores = []
    }

    override func tearDown() async throws {
        stores.forEach { $0.close() }
        await server.release()
        try? FileManager.default.removeItem(at: directory)
    }

    private func at(_ day: Int, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func plan() -> DayPlan {
        var plan = SampleData.dayPlan
        plan.id = UUID()
        plan.date = at(21, 9)
        return plan
    }

    private func makeStore() -> GroupPlanStore {
        let clock = ManualSleeper()
        let store = GroupPlanStore(userID: "user-1", server: server, directory: directory, calendar: calendar,
                                   now: { [unowned self] in self.at(20) }, sleep: { try await clock.sleep($0) })
        stores.append(store)
        return store
    }

    /// Jordan's group, which you're not in yet; returns its id and link token.
    private func jordansGroup(others: [String] = []) async -> (UUID, String) {
        let id = await server.seedGroup(plan: plan(), date: "2026-11-21", organizer: "Jordan", others: others, youAreMember: false)
        let token = await server.info(id)!.token
        return (id, token)
    }

    // MARK: - Preview (GE-2)

    func testShowsWhoseDayItIsAndHowManyAreIn() async {
        let (_, token) = await jordansGroup(others: ["Ava"])
        let model = JoinGroupModel(token: token, groups: makeStore())
        XCTAssertEqual(model.state, .loading)

        await model.load()

        XCTAssertEqual(model.state, .ready(GroupInvitePreview(organizerName: "Jordan", date: "2026-11-21", memberCount: 2)))
        let calls = await server.calls
        XCTAssertEqual(calls, [.preview], "looking doesn't join")
    }

    func testJoinAddsTheGroupAndOpensIt() async {
        let (id, token) = await jordansGroup()
        let store = makeStore()
        let model = JoinGroupModel(token: token, groups: store)
        await model.load()

        await model.join()

        XCTAssertEqual(model.state, .joined(id))
        XCTAssertEqual(store.groups.map(\.id), [id])
        XCTAssertEqual(store.group(id)?.members.map(\.name), ["Jordan", "Sofia"])
    }

    // MARK: - JN-2: a link that doesn't work

    func testADeadLinkSaysTheInviteDoesntWork() async {
        let model = JoinGroupModel(token: "AAAAAAAAAAAAAAAAAAAAAA", groups: makeStore())

        await model.load()

        XCTAssertEqual(model.state, .gone)
    }

    /// Full and replaced are the same 404 (N-17), so they look the same.
    func testAFullGroupAndAReplacedLinkLookTheSame() async throws {
        let (_, full) = await jordansGroup(others: ["A", "B", "C", "D", "E", "F", "G"])
        let replacedGroup = await server.seedGroup(plan: plan(), date: "2026-11-21", organizer: nil)
        let info = await server.info(replacedGroup)
        let replaced = try XCTUnwrap(info?.token)
        _ = try await server.newInvite(replacedGroup)
        let store = makeStore()

        let fullModel = JoinGroupModel(token: full, groups: store)
        await fullModel.load()
        let replacedModel = JoinGroupModel(token: replaced, groups: store)
        await replacedModel.load()

        XCTAssertEqual(fullModel.state, .gone)
        XCTAssertEqual(replacedModel.state, .gone)
    }

    func testALinkThatStopsWorkingBeforeJoinSaysSo() async {
        let (_, token) = await jordansGroup()
        let store = makeStore()
        let model = JoinGroupModel(token: token, groups: store)
        await model.load()
        await server.script(.join, .gone)

        await model.join()

        XCTAssertEqual(model.state, .gone)
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - No answer

    func testNoAnswerToThePreviewCanBeTriedAgain() async {
        let (_, token) = await jordansGroup()
        await server.script(.preview, .network)
        let model = JoinGroupModel(token: token, groups: makeStore())

        await model.load()
        XCTAssertEqual(model.state, .offline)

        await model.retry()
        XCTAssertEqual(model.state, .ready(GroupInvitePreview(organizerName: "Jordan", date: "2026-11-21", memberCount: 1)))
    }

    func testNoAnswerToJoinTriesTheJoinAgain() async {
        let (id, token) = await jordansGroup()
        let store = makeStore()
        let model = JoinGroupModel(token: token, groups: store)
        await model.load()
        await server.script(.join, .network)

        await model.join()
        XCTAssertEqual(model.state, .offline)
        XCTAssertTrue(store.groups.isEmpty)

        await model.retry()
        XCTAssertEqual(model.state, .joined(id))
        let calls = await server.calls
        XCTAssertEqual(calls, [.preview, .join, .join], "Try again joins; it doesn't start over")
    }

    func testAnotherFailureSaysSoAndCanBeTriedAgain() async {
        let (id, token) = await jordansGroup()
        let model = JoinGroupModel(token: token, groups: makeStore())
        await model.load()
        await server.script(.join, .status(503))

        await model.join()
        guard case .problem = model.state else { return XCTFail("\(model.state)") }

        await model.retry()
        XCTAssertEqual(model.state, .joined(id))
    }

    // MARK: - JN-3: no duplicates

    func testJoiningTwiceKeepsOneGroup() async {
        let (id, token) = await jordansGroup()
        let store = makeStore()

        let first = JoinGroupModel(token: token, groups: store)
        await first.load()
        await first.join()
        let second = JoinGroupModel(token: token, groups: store)
        await second.load()
        await second.join()

        XCTAssertEqual(first.state, .joined(id))
        XCTAssertEqual(second.state, .joined(id))
        XCTAssertEqual(store.groups.map(\.id), [id])
        let names = await server.info(id)?.memberNames
        XCTAssertEqual(names, ["Jordan", "Sofia"])
    }

    func testTheOrganizersOwnLinkJustOpensTheGroup() async throws {
        let store = makeStore()
        let id = try await store.create(from: plan()).get()
        let link = try XCTUnwrap(store.group(id)?.inviteUrl)
        let token = try XCTUnwrap(InviteLink.token(in: link))
        let before = await server.calls

        let model = JoinGroupModel(token: token, groups: store)
        await model.load()

        XCTAssertEqual(model.state, .joined(id))
        XCTAssertEqual(store.groups.map(\.id), [id])
        let after = await server.calls
        XCTAssertEqual(after, before, "no preview, no join")
    }

    // MARK: - An account without group plans

    func testALocalOnlyAccountIsToldGroupPlansNeedAnAccount() async {
        let model = JoinGroupModel(token: FakeGroupPlanServer.joinableToken, groups: nil)

        await model.load()
        XCTAssertEqual(model.state, .needsAccount)
        await model.join()
        XCTAssertEqual(model.state, .needsAccount)
    }

    // MARK: - Words

    private let english = Locale(identifier: "en_US")

    func testTheDayInWords() {
        let now = at(20)
        func day(_ date: String) -> String { JoinGroupText.day(date, now: now, calendar: calendar, locale: english) }
        XCTAssertEqual(day("2026-11-20"), "today")
        XCTAssertEqual(day("2026-11-21"), "tomorrow")
        XCTAssertEqual(day("2026-11-22"), "Sunday")
        XCTAssertEqual(day("2026-11-26"), "Thursday")
        XCTAssertEqual(day("2026-11-27"), "Friday, November 27")
        XCTAssertEqual(day("2026-11-19"), "Thursday, November 19")
        XCTAssertEqual(day("someday"), "someday")
    }

    func testTheQuestion() {
        let preview = GroupInvitePreview(organizerName: "Maya", date: "2026-11-21", memberCount: 3)
        XCTAssertEqual(JoinGroupText.question(preview, now: at(19), calendar: calendar, locale: english), "Join Maya's plan for Saturday?")
        XCTAssertEqual(JoinGroupText.question(preview, now: at(21), calendar: calendar, locale: english), "Join Maya's plan for today?")
        XCTAssertEqual(JoinGroupText.nameNote, "Your first name will show to the group.")
    }

    func testHowManyAreIn() {
        XCTAssertEqual(JoinGroupText.members(GroupInvitePreview(organizerName: "Jordan", date: "2026-11-21", memberCount: 1)), "Just Jordan so far.")
        XCTAssertEqual(JoinGroupText.members(GroupInvitePreview(organizerName: "Jordan", date: "2026-11-21", memberCount: 2)), "2 people in the group so far.")
    }

    func testTheWordsForEachProblem() {
        XCTAssertEqual(JoinGroupText.goneTitle, "This invite doesn't work any more")
        let all = [JoinGroupText.goneTitle, JoinGroupText.goneMessage, JoinGroupText.offlineTitle, JoinGroupText.offlineMessage,
                   JoinGroupText.problemTitle, JoinGroupText.problemMessage, JoinGroupText.needsAccountTitle,
                   JoinGroupText.needsAccountMessage, JoinGroupText.loading, JoinGroupText.nameNote]
        for text in all {
            XCTAssertFalse(text.isEmpty)
            for word in ["discover", "explore", "itinerary", "cheap", "hidden gems", "curated", "seamless", "elevate", "AI-powered"] {
                XCTAssertFalse(text.lowercased().contains(word.lowercased()), "\(word) in \(text)")
            }
        }
    }
}
