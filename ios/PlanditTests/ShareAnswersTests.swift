import XCTest
@testable import Plandit

/// Friends' answers on the shared plan's page, in the organizer's app (group plans, mode 1):
/// GV-5 (Today shows them, refreshed at most every 10 s), GV-6 ("Swap it" and Undo) and GV-7
/// (removing one).
@MainActor final class ShareAnswersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlanditStore.shareUpdateDelay = .milliseconds(50)
    }

    // MARK: - Reading the server's answers

    func testDecodesTheServersAnswers() throws {
        let stop = UUID(), alternate = UUID(), other = UUID()
        let json = """
        {"answers": [
          {"id": "6f1c2a4e-1b2c-4d3e-8f90-a1b2c3d4e5f6", "name": "Maya", "status": "in",
           "swaps": {"\(stop.uuidString.lowercased())": "\(alternate.uuidString.lowercased())", "\(other.uuidString)": null},
           "createdAt": "2026-11-21T18:04:05Z", "updatedAt": "2026-11-21T18:05:00Z"},
          {"id": "7a1c2a4e-1b2c-4d3e-8f90-a1b2c3d4e5f6", "name": "Sam", "status": "out", "swaps": {},
           "createdAt": "2026-11-21T18:06:05Z", "updatedAt": "2026-11-21T18:06:05Z"},
          {"id": "8b1c2a4e-1b2c-4d3e-8f90-a1b2c3d4e5f6", "name": "Who", "status": "maybe", "swaps": {},
           "createdAt": "2026-11-21T18:06:05Z", "updatedAt": "2026-11-21T18:06:05Z"}
        ]}
        """
        let answers = try ShareAnswer.decodeList(Data(json.utf8))
        XCTAssertEqual(answers.map(\.name), ["Maya", "Sam"], "an answer this build can't read is skipped, not the whole list")
        XCTAssertEqual(answers[0].id, UUID(uuidString: "6F1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6"))
        XCTAssertEqual(answers[0].status, .in)
        XCTAssertEqual(answers[0].swaps[stop], .some(alternate), "ids match whatever their case")
        XCTAssertEqual(answers[0].swaps[other], .some(nil), "\"I'd swap this\" with no pick")
        XCTAssertEqual(answers[1].status, .out)
        XCTAssertEqual(answers[0].updatedAt, ISO8601DateFormatter().date(from: "2026-11-21T18:05:00Z"))
    }

    func testTheClientReadsTheOwnersAnswers() async throws {
        let transport = FakeTransport { _ in (200, Data(#"{"answers": []}"#.utf8)) }
        let client = ShareAnswersClient(api: api(transport))
        let answers = try await client.answers(slug: "k7Qx2aB9cD")
        XCTAssertEqual(answers, [])
        XCTAssertEqual(transport.requests("GET", pathContaining: "api/shares/k7Qx2aB9cD/answers/").count, 1)
    }

    func testOnTodaysServerA404MeansNoAnswers() async throws {
        // Production doesn't have the answers endpoint yet: that's "no answers", never an error.
        let transport = FakeTransport { _ in (404, Data(#"{"detail": "Not found."}"#.utf8)) }
        let answers = try await ShareAnswersClient(api: api(transport)).answers(slug: "abc")
        XCTAssertEqual(answers, [])
    }

    func testAServerErrorIsAnErrorNotAnEmptyList() async {
        let transport = FakeTransport { _ in (500, Data()) }
        do {
            _ = try await ShareAnswersClient(api: api(transport)).answers(slug: "abc")
            XCTFail("should throw")
        } catch {}
    }

    func testTheClientRemovesAnAnswerByItsID() async throws {
        let transport = FakeTransport { _ in (204, Data()) }
        let id = UUID()
        try await ShareAnswersClient(api: api(transport)).remove(slug: "abc", answerID: id)
        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/shares/abc/answers/\(id.uuidString)/").count, 1)

        // Already gone is what the organizer wanted.
        transport.respond { _ in (404, Data()) }
        try await ShareAnswersClient(api: api(transport)).remove(slug: "abc", answerID: id)

        transport.respond { _ in (500, Data()) }
        do {
            try await ShareAnswersClient(api: api(transport)).remove(slug: "abc", answerID: id)
            XCTFail("should throw")
        } catch {}
    }

    // MARK: - Today's summary (GV-5)

    func testTheSummaryCountsWhoIsInAndWhoCant() {
        XCTAssertEqual(ShareAnswersText.summary(inCount: 3, outCount: 1), "3 in · 1 can't make it")
        XCTAssertEqual(ShareAnswersText.summary(inCount: 2, outCount: 0), "2 in")
        XCTAssertEqual(ShareAnswersText.summary(inCount: 0, outCount: 2), "2 can't make it")
        XCTAssertNil(ShareAnswersText.summary(inCount: 0, outCount: 0))
        XCTAssertEqual(ShareAnswersText.wouldSwap(1), "1 would swap")
        XCTAssertEqual(ShareAnswersText.wouldSwap(2), "2 would swap")
    }

    func testTodayShowsCountsNamesAndSwapMarksAfterARefresh() async throws {
        let (store, answers) = try await sharedStore()
        let highLine = stop(named: "The High Line", in: store)
        let tacos = stop(named: "Los Tacos No. 1", in: store)
        await answers.set([
            answer("Maya", .in, swaps: [highLine.id: SampleData.littleIslandPost.id]),
            answer("Jordan", .in, swaps: [highLine.id: nil, tacos.id: nil]),
            answer("Sam", .out),
        ])
        XCTAssertNil(store.answerSummary, "nothing until the first refresh")

        await store.refreshShareAnswers()
        let summary = try XCTUnwrap(store.answerSummary)
        XCTAssertEqual(summary.text, "2 in · 1 can't make it")
        XCTAssertEqual(summary.inNames, ["Maya", "Jordan"])
        XCTAssertEqual(summary.outNames, ["Sam"])
        XCTAssertEqual(store.swapMarks[highLine.id]?.map(\.name), ["Maya", "Jordan"])
        XCTAssertEqual(store.swapMarks[highLine.id]?.map(\.alternateID), [SampleData.littleIslandPost.id, nil])
        XCTAssertEqual(store.swapMarks[tacos.id]?.count, 1)
    }

    func testAnswersRefreshAtMostEveryTenSeconds() async throws {
        let (store, answers) = try await sharedStore()
        let start = Date()
        await store.refreshShareAnswers(now: start)
        await store.refreshShareAnswers(now: start.addingTimeInterval(5))
        var calls = await answers.calls
        XCTAssertEqual(calls, 1, "Today appearing again within 10 s doesn't ask again")

        await store.refreshShareAnswers(now: start.addingTimeInterval(11))
        calls = await answers.calls
        XCTAssertEqual(calls, 2, "after 10 s it does")
    }

    func testAFailedRefreshKeepsWhatWasShownAndTriesAgainNextTime() async throws {
        let (store, answers) = try await sharedStore()
        await answers.set([answer("Maya", .in)])
        let start = Date()
        await store.refreshShareAnswers(now: start)
        await answers.failNext()
        await store.refreshShareAnswers(now: start.addingTimeInterval(11))
        XCTAssertEqual(store.answerSummary?.text, "1 in")
        await store.refreshShareAnswers(now: start.addingTimeInterval(12))
        let calls = await answers.calls
        XCTAssertEqual(calls, 3, "a failure doesn't count as a refresh")
    }

    func testNoLinkMeansNoAnswersAndNoRequests() async {
        let answers = RecordingAnswers()
        let store = makeStore()
        store.answerClient = answers
        await store.refreshShareAnswers()
        let calls = await answers.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(store.answerSummary)
    }

    func testSwapsAboutStopsNoLongerInThePlanOrAlreadyDoneAreNotShown() async throws {
        let (store, answers) = try await sharedStore()
        let met = stop(named: "The Met", in: store) // underway
        let tacos = stop(named: "Los Tacos No. 1", in: store)
        await answers.set([answer("Maya", .in, swaps: [met.id: nil, tacos.id: nil, UUID(): nil])])
        await store.refreshShareAnswers()
        XCTAssertEqual(Array(store.swapMarks.keys), [tacos.id])

        store.removeStop(tacos.id)
        XCTAssertTrue(store.swapMarks.isEmpty, "an answer about a stop that's gone disappears")
    }

    func testStoppingSharingForgetsTheAnswers() async throws {
        let (store, answers) = try await sharedStore()
        await answers.set([answer("Maya", .in)])
        await store.refreshShareAnswers()
        try await store.stopSharing()
        XCTAssertNil(store.answerSummary)
        XCTAssertTrue(store.shareAnswers.isEmpty)
    }

    // MARK: - Swap it (GV-6)

    func testSwapReplacesTheStopInPlaceReplansAndResharesAndUndoPutsItBack() async throws {
        let sharing = FakePlanSharing()
        let (store, answers) = try await sharedStore(sharing: sharing)
        let before = store.today
        let highLine = stop(named: "The High Line", in: store)
        let index = try XCTUnwrap(store.stopIndex(id: highLine.id))
        await answers.set([answer("Maya", .in, swaps: [highLine.id: SampleData.littleIslandPost.id])])
        await store.refreshShareAnswers()

        XCTAssertTrue(store.swap(stopID: highLine.id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        let plan = store.today
        XCTAssertEqual(plan.stops.count, before.stops.count)
        XCTAssertEqual(plan.stops[index].place.name, "Little Island", "same position")
        XCTAssertEqual(plan.stops[index].sourcePostID, SampleData.littleIslandPost.id)
        XCTAssertNil(plan.stop(id: highLine.id))
        XCTAssertEqual(plan.stops.map(\.place.name).filter { $0 != "Little Island" },
                       before.stops.map(\.place.name).filter { $0 != "The High Line" }, "every other stop stays, in order")
        for position in index..<plan.stops.count {
            let previous = plan.stops[position - 1]
            let arrival = previous.end.addingTimeInterval(TimeInterval((plan.leg(after: previous)?.minutes ?? 0) * 60))
            XCTAssertGreaterThanOrEqual(plan.stops[position].start, arrival, "times replanned from the swapped stop on")
        }
        XCTAssertEqual(plan.legs.count, plan.stops.count - 1)
        XCTAssertEqual(store.undo?.message, "Swapped The High Line for Little Island")
        XCTAssertTrue(store.swapMarks.isEmpty, "the stop friends would swap is gone")

        try await Task.sleep(for: .milliseconds(400))
        let last = await sharing.published.last
        let published = try XCTUnwrap(last)
        XCTAssertTrue(published.stops.contains { $0.name == "Little Island" }, "re-shared")
        XCTAssertFalse(published.stops.contains { $0.name == "The High Line" })

        store.undoLastChange()
        XCTAssertEqual(store.today.stops.map(\.id), before.stops.map(\.id))
        XCTAssertEqual(store.today.stops[index].start, before.stops[index].start)
    }

    func testSwapIsOnlyOfferedForAPlaceStillSavedAndNotAlreadyInThePlan() async throws {
        let (store, _) = try await sharedStore()
        XCTAssertEqual(store.swapAvailability(of: SampleData.littleIslandPost.id), .available)
        XCTAssertEqual(store.swapAvailability(of: SampleData.tacosPost.id), .alreadyInPlan)
        XCTAssertEqual(store.swapAvailability(of: UUID()), .notSaved)
        let tacos = stop(named: "Los Tacos No. 1", in: store)
        XCTAssertFalse(store.swap(stopID: tacos.id, toPost: SampleData.highLinePost.id), "already in the plan")
        let met = stop(named: "The Met", in: store)
        XCTAssertFalse(store.swap(stopID: met.id, toPost: SampleData.littleIslandPost.id), "a stop underway stays")
    }

    func testKeepItHidesTheMarkUntilAFriendPicksSomethingElse() async throws {
        let (store, answers) = try await sharedStore()
        let highLine = stop(named: "The High Line", in: store)
        await answers.set([answer("Maya", .in, swaps: [highLine.id: nil])])
        await store.refreshShareAnswers()
        XCTAssertEqual(store.swapMarks[highLine.id]?.count, 1)

        store.keepStop(highLine.id)
        XCTAssertNil(store.swapMarks[highLine.id])
        XCTAssertEqual(store.today.stops.map(\.id).contains(highLine.id), true, "the stop stays")

        await answers.set([answer("Maya", .in, swaps: [highLine.id: SampleData.littleIslandPost.id]), answer("Jordan", .in, swaps: [highLine.id: nil])])
        await store.refreshShareAnswers(force: true)
        XCTAssertEqual(store.swapMarks[highLine.id]?.map(\.name), ["Maya", "Jordan"], "a new pick shows again")
    }

    // MARK: - Removing an answer (GV-7)

    func testRemovingAnAnswerTakesItOffTheServerAndToday() async throws {
        let (store, answers) = try await sharedStore()
        let maya = answer("Maya", .in)
        await answers.set([maya, answer("Sam", .out)])
        await store.refreshShareAnswers()

        try await store.removeShareAnswer(maya.id)
        XCTAssertEqual(store.answerSummary?.text, "1 can't make it")
        let removed = await answers.removed
        XCTAssertEqual(removed, [maya.id])
    }

    func testAFailedRemovalKeepsTheAnswer() async throws {
        let (store, answers) = try await sharedStore()
        let maya = answer("Maya", .in)
        await answers.set([maya])
        await store.refreshShareAnswers()
        await answers.failNext()
        do {
            try await store.removeShareAnswer(maya.id)
            XCTFail("should throw")
        } catch {}
        XCTAssertEqual(store.answerSummary?.text, "1 in")
    }

    // MARK: - Helpers

    private func makeStore(sharing: FakePlanSharing = FakePlanSharing()) -> PlanditStore {
        let store = PlanditStore(today: SampleData.dayPlan, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        return store
    }

    private func sharedStore(sharing: FakePlanSharing = FakePlanSharing()) async throws -> (PlanditStore, RecordingAnswers) {
        let store = makeStore(sharing: sharing)
        let answers = RecordingAnswers()
        store.answerClient = answers
        try await store.shareToday(showPrices: true, note: "")
        return (store, answers)
    }

    private func stop(named name: String, in store: PlanditStore) -> PlanStop {
        store.today.stops.first { $0.place.name == name }!
    }

    private func answer(_ name: String, _ status: ShareAnswer.Status, swaps: [UUID: UUID?] = [:]) -> ShareAnswer {
        ShareAnswer(id: UUID(), name: name, status: status, swaps: swaps, createdAt: Date(), updatedAt: Date())
    }

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: URL(string: "https://api.example")!, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }
}

/// Answers the test sets, and what the store asked for.
private actor RecordingAnswers: ShareAnswersFetching {
    private var answers: [ShareAnswer] = []
    private var failsNext = false
    private(set) var calls = 0
    private(set) var removed: [UUID] = []

    func set(_ answers: [ShareAnswer]) { self.answers = answers }
    func failNext() { failsNext = true }

    func answers(slug: String) async throws -> [ShareAnswer] {
        calls += 1
        if failsNext {
            failsNext = false
            throw APIError.network
        }
        return answers
    }

    func remove(slug: String, answerID: UUID) async throws {
        if failsNext {
            failsNext = false
            throw APIError.network
        }
        removed.append(answerID)
        answers.removeAll { $0.id == answerID }
    }
}
