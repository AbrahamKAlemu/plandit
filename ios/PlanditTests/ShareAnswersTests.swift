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

    func testTwoRefreshesAtLaunchAskOnce() async throws {
        // The app becoming active and Today appearing both ask before the first answer is back.
        let (store, answers) = try await sharedStore()
        await answers.set([answer("Maya", .in)])
        let start = Date()
        await answers.holdNext()
        let first = Task { await store.refreshShareAnswers(now: start) }
        try await waitUntilHeld(answers)
        await store.refreshShareAnswers(now: start.addingTimeInterval(0.5))
        await answers.release()
        await first.value
        let calls = await answers.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.answerSummary?.text, "1 in")
    }

    func testAFirstRefreshThatFailsTriesAgainNextTime() async throws {
        let (store, answers) = try await sharedStore()
        await answers.set([answer("Maya", .in)])
        await answers.failNext()
        let start = Date()
        await store.refreshShareAnswers(now: start)
        XCTAssertNil(store.answerSummary)
        await store.refreshShareAnswers(now: start.addingTimeInterval(1))
        let calls = await answers.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.answerSummary?.text, "1 in")
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
        XCTAssertEqual(store.undo?.message, "Swapped The High Line for Little Island. Your link updates too.")
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

    func testUndoingASwapBeforeThePageUpdatesPublishesNothing() async throws {
        let sharing = FakePlanSharing()
        let (store, _) = try await sharedStore(sharing: sharing)
        let before = await sharing.published.count
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        store.undoLastChange()

        try await Task.sleep(for: .milliseconds(400))
        let published = await sharing.published
        XCTAssertEqual(published.count, before, "the page already shows the plan as it is again")
        XCTAssertFalse(published.contains { $0.stops.contains { $0.name == "Little Island" } }, "the swapped plan never goes out")
    }

    func testAChangeKeptThroughAnotherSaveStillPublishesOnce() async throws {
        let sharing = FakePlanSharing()
        let (store, _) = try await sharedStore(sharing: sharing)
        let before = await sharing.published.count
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        // Another save before the page updates, which doesn't change what the page shows.
        store.updateProfile { $0.name = "Abe" }

        try await Task.sleep(for: .milliseconds(400))
        let published = await sharing.published
        XCTAssertEqual(published.count, before + 1)
        XCTAssertTrue(published.last?.stops.contains { $0.name == "Little Island" } ?? false)
    }

    func testUndoWhileTheSwapIsBeingSentPublishesTheRestoredPlanLast() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        try await waitUntilHolding(sharing)
        store.undoLastChange()
        sharing.release()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sharing.published.count, 3, "shared, the swap, then the plan put back")
        XCTAssertTrue(sharing.published[1].stops.contains { $0.name == "Little Island" }, "the swap went out whole")
        XCTAssertEqual(sharing.published.last?.stops.map(\.name), store.today.stops.map(\.place.name), "the page ends on the plan as it is")
        XCTAssertEqual(sharing.mostAtOnce, 1, "one at a time")

        store.updateProfile { $0.name = "Abe" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sharing.published.count, 3, "and then the page is up to date: nothing more to send")
    }

    func testChangesWhileAnUpdateIsBeingSentGoOutAfterItEndingWithTheLatest() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        try await waitUntilHolding(sharing)
        store.removeStop(stop(named: "Los Tacos No. 1", in: store).id)
        try await Task.sleep(for: .milliseconds(100))
        store.removeStop(stop(named: "Joe's Pizza", in: store).id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sharing.published.count, 1, "nothing else goes out while one is")
        sharing.release()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sharing.published.count, 3, "the swap, then the latest plan")
        XCTAssertEqual(sharing.published.last?.stops.map(\.name), store.today.stops.map(\.place.name))
        XCTAssertEqual(sharing.mostAtOnce, 1)
    }

    func testSharingAgainDropsTheUpdateThatWasWaiting() async throws {
        let (store, sharing) = try await holdingStore()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        // The page update is waiting; Share plan sends new options, slowly.
        sharing.holdNext()
        let share = Task { try await store.shareToday(showPrices: true, note: "New note") }
        try await waitUntilHolding(sharing)
        try await Task.sleep(for: .milliseconds(200))
        sharing.release()
        try await share.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sharing.published.dropFirst().map(\.note), ["New note"], "nothing with the old options goes out")
        XCTAssertTrue(sharing.published.last?.stops.contains { $0.name == "Little Island" } ?? false)
        XCTAssertEqual(sharing.mostAtOnce, 1)
    }

    func testSharingAgainWaitsForTheUpdateBeingSent() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        try await waitUntilHolding(sharing)
        let share = Task { try await store.shareToday(showPrices: true, note: "New note") }
        try await Task.sleep(for: .milliseconds(100))
        sharing.release()
        try await share.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sharing.published.last?.note, "New note", "the new options land last")
        XCTAssertEqual(sharing.mostAtOnce, 1)
    }

    func testStoppingSharingDropsTheUpdateThatWasWaiting() async throws {
        let (store, sharing) = try await holdingStore()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        sharing.holdNext()
        let stopping = Task { try await store.stopSharing() }
        try await waitUntilHolding(sharing)
        try await Task.sleep(for: .milliseconds(200))
        sharing.release()
        try await stopping.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sharing.applied, ["publish", "unpublish"], "shared, then taken down: nothing in between or after")
        XCTAssertNil(store.todayLink)
    }

    func testStoppingSharingWaitsForTheUpdateBeingSent() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        XCTAssertTrue(store.swap(stopID: stop(named: "The High Line", in: store).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        try await waitUntilHolding(sharing)
        let stopping = Task { try await store.stopSharing() }
        try await Task.sleep(for: .milliseconds(100))
        sharing.release()
        try await stopping.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sharing.applied, ["publish", "publish", "unpublish"], "the page is taken down last")
        XCTAssertEqual(sharing.mostAtOnce, 1)
    }

    func testStopSharingQueuedBehindShareAgainLeavesThePageDown() async throws {
        // GV-10: Share plan is out on a slow server and Stop sharing waits behind it.
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        let share = Task { try await store.shareToday(showPrices: true, note: "New") }
        try await waitUntilHolding(sharing)
        let stopping = Task { try await store.stopSharing() }
        try await Task.sleep(for: .milliseconds(50))
        sharing.release()
        _ = try await share.value
        try await stopping.value
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sharing.applied, ["publish", "publish", "unpublish"], "nothing goes out after Stop sharing")
        XCTAssertNil(store.todayLink)
    }

    func testAnEditWhileStopSharingIsOutSendsNothingAfterIt() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        let stopping = Task { try await store.stopSharing() }
        try await waitUntilHolding(sharing)
        store.removeStop(stop(named: "Joe's Pizza", in: store).id)
        sharing.release()
        try await stopping.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sharing.applied, ["publish", "unpublish"])
    }

    func testAnEditWhileShareFailsStillGoesOutWithTheLink() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        let share = Task { try await store.shareToday(showPrices: true, note: "New") }
        try await waitUntilHolding(sharing)
        store.removeStop(stop(named: "Joe's Pizza", in: store).id)
        share.cancel() // the app sees Share plan fail
        sharing.release()
        _ = try? await share.value
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sharing.published.last?.stops.count, store.today.stops.count, "the change made meanwhile goes out")
        XCTAssertNotNil(store.todayLink)
    }

    func testShareFailingWhileStopSharingWaitsLeavesNothingHeldOrSent() async throws {
        let (store, sharing) = try await holdingStore()
        sharing.holdNext()
        let share = Task { try await store.shareToday(showPrices: true, note: "New") }
        try await waitUntilHolding(sharing)
        let stopping = Task { try await store.stopSharing() }
        try await Task.sleep(for: .milliseconds(50))
        store.removeStop(stop(named: "Joe's Pizza", in: store).id)
        share.cancel() // Share plan fails
        sharing.release()
        _ = try? await share.value
        try await stopping.value
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(sharing.applied.last, "unpublish", "the page stays down")
        XCTAssertNil(store.todayLink)
        let applied = sharing.applied.count
        store.removeStop(stop(named: "Los Tacos No. 1", in: store).id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sharing.applied.count, applied, "no link: edits send nothing")

        // Nothing is left holding updates: sharing again works, and so do edits after it.
        try await store.shareToday(showPrices: true, note: "")
        store.removeStop(stop(named: "Washington Square Park", in: store).id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sharing.published.last?.stops.map(\.name), store.today.stops.map(\.place.name))
        XCTAssertEqual(sharing.mostAtOnce, 1)
    }

    func testTheSwapUndoBarOnlyMentionsTheLinkWhenItUpdates() async throws {
        let unshared = makeStore()
        XCTAssertTrue(unshared.swap(stopID: stop(named: "The High Line", in: unshared).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        XCTAssertEqual(unshared.undo?.message, "Swapped The High Line for Little Island", "no link")

        let (signedOut, _) = try await sharedStore()
        signedOut.sharing = nil
        XCTAssertTrue(signedOut.swap(stopID: stop(named: "The High Line", in: signedOut).id, toPost: SampleData.littleIslandPost.id, now: SampleData.at(11)))
        XCTAssertEqual(signedOut.undo?.message, "Swapped The High Line for Little Island", "can't update the link")
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

    func testKeepItSurvivesTheServerDroppingThePick() async throws {
        // The server turns a pick into "no pick" when the place is no longer offered for the stop
        // (swaps turned off, or the same place swapped in elsewhere).
        let (store, answers) = try await sharedStore()
        let highLine = stop(named: "The High Line", in: store)
        let maya = answer("Maya", .in, swaps: [highLine.id: SampleData.littleIslandPost.id])
        await answers.set([maya])
        await store.refreshShareAnswers()
        store.keepStop(highLine.id)
        XCTAssertNil(store.swapMarks[highLine.id])

        var rewritten = maya
        rewritten.swaps = [highLine.id: nil]
        await answers.set([rewritten])
        await store.refreshShareAnswers(force: true)
        XCTAssertNil(store.swapMarks[highLine.id], "still kept")
    }

    func testKeepItShowsAFriendAgainWhoPicksAnotherPlace() async throws {
        let (store, answers) = try await sharedStore()
        let highLine = stop(named: "The High Line", in: store)
        let maya = answer("Maya", .in, swaps: [highLine.id: SampleData.littleIslandPost.id])
        await answers.set([maya])
        await store.refreshShareAnswers()
        store.keepStop(highLine.id)

        var changed = maya
        changed.swaps = [highLine.id: SampleData.levainPost.id]
        await answers.set([changed])
        await store.refreshShareAnswers(force: true)
        XCTAssertEqual(store.swapMarks[highLine.id]?.map(\.alternateID), [SampleData.levainPost.id], "a new pick shows again")

        store.keepStop(highLine.id)
        XCTAssertNil(store.swapMarks[highLine.id])
        XCTAssertEqual(store.todayLink?.keptSwaps.count, 1, "one kept pick per friend and stop")
    }

    func testKeptPicksSavedBeforeStillLoadAndHide() throws {
        let store = makeStore()
        let highLine = stop(named: "The High Line", in: store)
        let mayaID = UUID()
        let pick = SampleData.littleIslandPost.id
        let json = """
        {"slug": "abc", "url": "https://plandit.app/p/abc", "planID": "\(store.today.id.uuidString)", "showPrices": true,
         "note": "", "suggestsSwaps": true, "keptSwaps": ["\(highLine.id.uuidString)/\(mayaID.uuidString)/\(pick.uuidString)"]}
        """
        let link = try JSONDecoder().decode(SharedLink.self, from: Data(json.utf8))
        let kept = Set(link.keptSwaps)
        func marks(_ pick: UUID?) -> [UUID: [SwapPick]] {
            let maya = ShareAnswer(id: mayaID, name: "Maya", status: .in, swaps: [highLine.id: pick], createdAt: Date(), updatedAt: Date())
            return ShareAnswers.swapMarks([maya], plan: store.today, kept: kept)
        }
        XCTAssertNil(marks(pick)[highLine.id], "the same pick")
        XCTAssertNil(marks(nil)[highLine.id], "the pick dropped by the server")
        XCTAssertEqual(marks(SampleData.levainPost.id)[highLine.id]?.count, 1, "another pick")
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

    func testASlowRefreshDoesntBringBackAnAnswerJustRemoved() async throws {
        let (store, answers) = try await sharedStore()
        let maya = answer("Maya", .in)
        await answers.set([maya, answer("Sam", .out)])
        await store.refreshShareAnswers()

        // A refresh goes out while Maya is still on the page...
        await answers.holdNext()
        let refresh = Task { await store.refreshShareAnswers(force: true) }
        try await waitUntilHeld(answers)
        // ...the organizer removes her, and then the refresh's answer, Maya included, comes back.
        try await store.removeShareAnswer(maya.id)
        await answers.release()
        await refresh.value
        XCTAssertEqual(store.shareAnswers.map(\.name), ["Sam"], "Maya stays gone")

        await store.refreshShareAnswers(force: true)
        XCTAssertEqual(store.shareAnswers.map(\.name), ["Sam"], "and the next refresh still works")
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

    /// A shared plan on a server that can be slow.
    private func holdingStore() async throws -> (PlanditStore, HoldingSharing) {
        let sharing = HoldingSharing()
        let store = PlanditStore(today: SampleData.dayPlan, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        try await store.shareToday(showPrices: true, note: "")
        return (store, sharing)
    }

    private func waitUntilHolding(_ sharing: HoldingSharing) async throws {
        for _ in 0..<200 {
            if sharing.isHolding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the request never went out")
    }

    /// Until the held request has gone out.
    private func waitUntilHeld(_ answers: RecordingAnswers) async throws {
        for _ in 0..<200 {
            if await answers.isHolding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the request never went out")
    }

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: URL(string: "https://api.example")!, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }
}

/// A server whose next request can be held part-way, as on a slow connection. Like the server, a
/// held request is applied even if the app gives up on it, and the app then sees it cancelled, as
/// URLSession reports it.
@MainActor private final class HoldingSharing: PlanSharing {
    private(set) var published: [SharedPlanPayload] = []
    /// What the server applied, in order: "publish" or "unpublish".
    private(set) var applied: [String] = []
    /// The most requests out at the same time.
    private(set) var mostAtOnce = 0
    private var atOnce = 0
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func holdNext() { holdsNext = true }
    func release() {
        held?.resume()
        held = nil
    }

    private func arrive() async {
        atOnce += 1
        mostAtOnce = max(mostAtOnce, atOnce)
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
        }
        atOnce -= 1
    }

    func publish(_ payload: SharedPlanPayload) async throws -> (slug: String, url: URL) {
        await arrive()
        published.append(payload)
        applied.append("publish")
        try Task.checkCancellation()
        return ("test123abc", URL(string: "https://plandit.app/p/test123abc")!)
    }

    func unpublish(slug: String) async throws {
        await arrive()
        applied.append("unpublish")
        try Task.checkCancellation()
    }
}

/// Answers the test sets, and what the store asked for.
private actor RecordingAnswers: ShareAnswersFetching {
    private var answers: [ShareAnswer] = []
    private var failsNext = false
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    private(set) var removed: [UUID] = []

    func set(_ answers: [ShareAnswer]) { self.answers = answers }
    func failNext() { failsNext = true }
    /// The next request waits for `release()`, then answers with what was set when it was asked.
    func holdNext() { holdsNext = true }
    func release() {
        held?.resume()
        held = nil
    }
    var isHolding: Bool { held != nil }

    func answers(slug: String) async throws -> [ShareAnswer] {
        calls += 1
        if failsNext {
            failsNext = false
            throw APIError.network
        }
        let answers = self.answers
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
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
