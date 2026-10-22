import XCTest
@testable import Plandit

/// The + flow end to end through the store: picking saved posts, building, and continuing a day.
final class PlanBuildingTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    @MainActor private func makeStore(stops: [PlanStop] = [], travel: String = "Walk + subway", storage: SnapshotStore? = nil) -> PlanditStore {
        var plan = DayPlan(date: .now, title: "Today", budget: 60, stops: stops, legs: [])
        plan.legs = zip(plan.stops, plan.stops.dropFirst()).map { .estimate(from: $0, to: $1) }
        var profile = SampleData.profile
        profile.travelModes = travel
        return PlanditStore(today: plan, saved: SampleData.savedPosts, profile: profile, stats: SampleData.stats,
                            pastPlans: [], visited: [], extractor: NoExtractor(), storage: storage)
    }

    @MainActor private func stop(_ place: Place, hour: Int, status: StopStatus, cost: Double = 5) -> PlanStop {
        PlanStop(place: place, start: SampleData.at(hour), durationMinutes: 60, estimatedCost: cost, status: status)
    }

    // MARK: - Start over

    @MainActor func testBuildingFromScratchPlansThePickedPosts() {
        let store = makeStore()
        let picks = [SampleData.tacosPost, SampleData.levainPost, SampleData.highLinePost]
        let outcome = store.buildPlan(postIDs: picks.map(\.id), start: SampleData.at(10), budget: 50, mode: .replace)

        XCTAssertEqual(outcome.stops.count, 3)
        XCTAssertEqual(store.today.stops.map(\.id), outcome.stops.map(\.id))
        XCTAssertEqual(Set(store.today.stops.compactMap(\.sourcePostID)), Set(picks.map(\.id)))
        XCTAssertEqual(store.today.legs.count, 2)
        XCTAssertEqual(store.today.budget, 50)
        XCTAssertLessThanOrEqual(store.today.totalCost, 50)
        XCTAssertEqual(store.today.stops.first?.start, SampleData.at(10))
        XCTAssertNotEqual(store.today.title, "Today", "the plan gets a name from where it goes")
        XCTAssertTrue(picks.allSatisfy(store.isInToday))
    }

    @MainActor func testStartOverReplacesAnExistingPlan() {
        let store = makeStore(stops: [stop(SampleData.met, hour: 9, status: .done), stop(SampleData.joesPizza, hour: 12, status: .upcoming)])
        store.buildPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(14), budget: 60, mode: .replace)
        XCTAssertEqual(store.today.stops.map(\.place.name), ["Levain Bakery"])
        XCTAssertEqual(store.today.stops.first?.status, .upcoming)
        XCTAssertTrue(store.today.legs.isEmpty)
    }

    @MainActor func testPostsWithoutAPlaceAreIgnored() {
        let store = makeStore()
        let outcome = store.buildPlan(postIDs: [SampleData.processingPost.id, SampleData.failedPost.id, UUID(), SampleData.levainPost.id],
                                      start: SampleData.at(10), budget: 60, mode: .replace)
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Levain Bakery"])
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    @MainActor func testPickingTheSamePostTwiceAddsItOnce() {
        let store = makeStore()
        store.buildPlan(postIDs: [SampleData.levainPost.id, SampleData.levainPost.id], start: SampleData.at(10), budget: 60, mode: .replace)
        XCTAssertEqual(store.today.stops.count, 1)
    }

    @MainActor func testPlannablePostsAreOnlyMappedOnes() {
        let store = makeStore()
        XCTAssertTrue(store.plannablePosts.allSatisfy(\.isMappable))
        XCTAssertFalse(store.plannablePosts.contains { $0.id == SampleData.processingPost.id || $0.id == SampleData.failedPost.id })
        XCTAssertTrue(store.plannablePosts.contains { $0.id == SampleData.smallsPost.id }, "needs-review posts still have a place")
    }

    // MARK: - Add to today

    @MainActor func testAddingKeepsDoneStopsAndReordersTheRest() {
        let done = stop(SampleData.hungarianPastry, hour: 9, status: .done, cost: 9)
        let now = stop(SampleData.met, hour: 10, status: .now)
        let later = stop(SampleData.joesPizza, hour: 15, status: .upcoming, cost: 7)
        let store = makeStore(stops: [done, now, later])

        store.buildPlan(postIDs: [SampleData.levainPost.id, SampleData.tacosPost.id], start: SampleData.at(8), budget: 80, mode: .add)

        let stops = store.today.stops
        XCTAssertEqual(stops.prefix(2).map(\.id), [done.id, now.id], "done and current stops never move")
        XCTAssertEqual(stops.prefix(2).map(\.status), [.done, .now])
        XCTAssertEqual(stops.count, 5)
        XCTAssertTrue(stops.contains { $0.id == later.id }, "an upcoming stop keeps its identity when re-ordered")
        XCTAssertTrue(stops.dropFirst(2).allSatisfy { $0.status == .upcoming })
        XCTAssertGreaterThanOrEqual(stops[2].start, now.end, "new stops start after the current one")
        // Levain is a short walk from the Met, so it comes next.
        XCTAssertEqual(stops[2].place.name, "Levain Bakery")

        XCTAssertEqual(store.today.legs.count, 4)
        for (index, leg) in store.today.legs.enumerated() {
            XCTAssertEqual(leg.fromStopID, stops[index].id)
            XCTAssertEqual(leg.toStopID, stops[index + 1].id)
        }
        XCTAssertLessThanOrEqual(store.today.totalCost, 80)
    }

    @MainActor func testAddingAPostAlreadyInThePlanDoesNotDuplicateIt() {
        let store = makeStore()
        store.buildPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(10), budget: 60, mode: .replace)
        store.buildPlan(postIDs: [SampleData.levainPost.id, SampleData.metPost.id], start: SampleData.at(10), budget: 60, mode: .add)
        XCTAssertEqual(store.today.stops.filter { $0.place.name == "Levain Bakery" }.count, 1)
        XCTAssertEqual(store.today.stops.count, 2)
    }

    @MainActor func testAddingToAnUntouchedPlanUsesTheChosenStart() {
        let store = makeStore(stops: [stop(SampleData.joesPizza, hour: 12, status: .upcoming)])
        store.buildPlan(postIDs: [SampleData.highLinePost.id], start: SampleData.at(13), budget: 60, mode: .add)
        XCTAssertEqual(store.today.stops.count, 2)
        XCTAssertEqual(store.today.stops.first?.start, SampleData.at(13))
    }

    @MainActor func testMoneySpentEarlierCountsWhenAdding() {
        let store = makeStore(stops: [stop(SampleData.met, hour: 10, status: .now, cost: 50)])
        XCTAssertEqual(store.lockedCost, 50)
        let outcome = store.buildPlan(postIDs: [SampleData.tacosPost.id, SampleData.levainPost.id], start: SampleData.at(8), budget: 60, mode: .add)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.overBudget])
        XCTAssertLessThanOrEqual(store.today.totalCost, 60)
    }

    @MainActor func testWithNoNewPicksAddJustReordersTheRestOfTheDay() {
        // Picked out of order: Village, then uptown, then Village again.
        let a = stop(SampleData.joesPizza, hour: 11, status: .upcoming)
        let b = stop(SampleData.cloisters, hour: 13, status: .upcoming)
        let c = stop(SampleData.washingtonSquare, hour: 16, status: .upcoming)
        let store = makeStore(stops: [a, b, c])
        let before = store.today.legs.reduce(0) { $0 + $1.minutes }
        store.buildPlan(postIDs: [], start: SampleData.at(11), budget: 60, mode: .add)
        XCTAssertEqual(Set(store.today.stops.map(\.id)), [a.id, b.id, c.id])
        XCTAssertLessThan(store.today.legs.reduce(0) { $0 + $1.minutes }, before)
    }

    // MARK: - Settings and persistence

    @MainActor func testWalkOnlyProfileOnlyWalks() {
        let store = makeStore(travel: "Walk only")
        store.buildPlan(postIDs: [SampleData.cloistersPost.id, SampleData.tacosPost.id], start: SampleData.at(10), budget: 60, mode: .replace)
        XCTAssertEqual(store.today.legs.map(\.mode), [.walk])
    }

    @MainActor func testPreviewChangesNothing() {
        let store = makeStore(stops: [stop(SampleData.met, hour: 10, status: .upcoming)])
        let before = store.today.stops.map(\.id)
        let preview = store.previewPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(10), budget: 60, mode: .replace)
        XCTAssertEqual(preview.stops.count, 1)
        XCTAssertEqual(store.today.stops.map(\.id), before)
    }

    @MainActor func testBuiltPlanIsSavedToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanBuildingTests-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }
        let store = makeStore(storage: storage)
        store.buildPlan(postIDs: [SampleData.levainPost.id, SampleData.metPost.id], start: SampleData.at(10), budget: 45, mode: .replace)
        store.flush()

        let loaded = try XCTUnwrap(storage.load())
        XCTAssertEqual(loaded.today.stops.map(\.id), store.today.stops.map(\.id))
        XCTAssertEqual(loaded.today.legs.map(\.id), store.today.legs.map(\.id))
        XCTAssertEqual(loaded.today.budget, 45)
        XCTAssertEqual(loaded.today.title, store.today.title)
    }

    // MARK: - Free until

    @MainActor func testFreeUntilKeepsTheDayInsideTheWindow() {
        let store = makeStore()
        let picks = [SampleData.levainPost, SampleData.metPost, SampleData.tacosPost, SampleData.highLinePost].map(\.id)
        let outcome = store.buildPlan(postIDs: picks, start: SampleData.at(13), budget: 100, mode: .replace, end: SampleData.at(16))
        XCTAssertFalse(outcome.skipped.isEmpty)
        XCTAssertTrue(outcome.skipped.allSatisfy { $0.reason == .outOfTime })
        XCTAssertLessThanOrEqual(store.today.stops.last?.end ?? .distantFuture, SampleData.at(16))
    }

    @MainActor func testFreeUntilAfterMidnightRollsToTheNextDay() {
        // 10 PM until 1 AM: the jazz club fits, it isn't "already over".
        let store = makeStore()
        let outcome = store.previewPlan(postIDs: [SampleData.smallsPost.id], start: SampleData.at(22), budget: 100, mode: .replace,
                                        end: SampleData.at(1))
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Smalls Jazz Club"])
        XCTAssertTrue(outcome.skipped.isEmpty)
    }

    @MainActor func testFreeUntilBeforeTheCurrentStopEndsMeansNothingFits() {
        let store = makeStore(stops: [stop(SampleData.met, hour: 14, status: .now)])
        let outcome = store.previewPlan(postIDs: [SampleData.levainPost.id], start: SampleData.at(9), budget: 100, mode: .add,
                                        end: SampleData.at(14, 30))
        XCTAssertTrue(outcome.stops.isEmpty)
        XCTAssertEqual(outcome.skipped.map(\.reason), [.outOfTime])
    }

    @MainActor func testEveningSpotIsLeftOutOfAnAfternoonWindow() {
        let store = makeStore()
        let outcome = store.previewPlan(postIDs: [SampleData.smallsPost.id, SampleData.levainPost.id], start: SampleData.at(13),
                                        budget: 100, mode: .replace, end: SampleData.at(17))
        XCTAssertEqual(outcome.stops.map(\.place.name), ["Levain Bakery"])
        XCTAssertEqual(outcome.skipped.map(\.reason), [.eveningOnly])
    }

    // MARK: - Sharing and saved dates

    @MainActor func testShareTextIsReadyForAGroupChat() {
        let store = makeStore()
        store.buildPlan(postIDs: [SampleData.cloistersPost.id, SampleData.tacosPost.id], start: SampleData.at(11), budget: 60, mode: .replace)
        let text = store.today.shareText
        let first = store.today.stops[0]
        XCTAssertTrue(text.hasPrefix(store.today.title))
        XCTAssertTrue(text.contains("Meet \(first.start.shortTime) at \(first.place.name), \(first.place.address)"))
        for stop in store.today.stops {
            XCTAssertTrue(text.contains("\(stop.start.shortTime)  \(stop.place.name) (\(stop.estimatedCost.dollarsText))"))
        }
        XCTAssertTrue(text.contains("About \(store.today.totalCost.wholeDollarsText) per person, including $2.90 in subway fares."))
        XCTAssertTrue(text.contains("Done by \(store.today.stops.last!.end.shortTime)."))
    }

    @MainActor func testShareTextForAWalkingDayHasNoFares() {
        let store = makeStore(travel: "Walk only")
        store.buildPlan(postIDs: [SampleData.tacosPost.id, SampleData.littleIslandPost.id], start: SampleData.at(11), budget: 60, mode: .replace)
        XCTAssertTrue(store.today.shareText.contains("About $15 per person. Done by"))
        XCTAssertTrue(store.today.shareText.contains("Little Island (Free)"))
    }

    @MainActor func testPreviewCountsSubwayRides() {
        let walk = TravelLeg(fromStopID: UUID(), toStopID: UUID(), mode: .walk, minutes: 10, miles: 0.5)
        let ride = TravelLeg(fromStopID: UUID(), toStopID: UUID(), mode: .subway, minutes: 20, miles: 3, cost: 2.90)
        XCTAssertNil(PlanPreview.subwayRidesText([walk]))
        XCTAssertEqual(PlanPreview.subwayRidesText([walk, ride]), "1 subway ride")
        XCTAssertEqual(PlanPreview.subwayRidesText([ride, walk, ride]), "2 subway rides")
    }

    @MainActor func testSavedAgoText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
        func text(daysAgo: Int) -> String {
            var post = SampleData.levainPost
            post.savedAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return post.savedAgoText(now: now, calendar: calendar)
        }
        XCTAssertEqual(text(daysAgo: 0), "Saved today")
        XCTAssertEqual(text(daysAgo: 1), "Saved yesterday")
        XCTAssertEqual(text(daysAgo: 3), "Saved 3 days ago")
        XCTAssertEqual(text(daysAgo: 20), "Saved 2 weeks ago")
        XCTAssertEqual(text(daysAgo: 95), "Saved 3 months ago")
        XCTAssertEqual(text(daysAgo: 400), "Saved over a year ago")
        XCTAssertEqual(text(daysAgo: 800), "Saved 2 years ago")
    }

    @MainActor func testPlanTitles() {
        XCTAssertEqual(PlanditStore.title(for: []), "Today")
        let one = PlanStop(place: SampleData.joesPizza, start: .now, durationMinutes: 30, estimatedCost: 0, status: .upcoming)
        XCTAssertEqual(PlanditStore.title(for: [one]), "A day in West Village")
        let two = PlanStop(place: SampleData.met, start: .now, durationMinutes: 30, estimatedCost: 0, status: .upcoming)
        XCTAssertEqual(PlanditStore.title(for: [two, one]), "Upper East Side to West Village")
    }

    @MainActor func testNextQuarterHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: h, minute: m, second: s))!
        }
        XCTAssertEqual(PlanBuilderSheet.nextQuarterHour(after: at(10, 7, 30), calendar: calendar), at(10, 15))
        XCTAssertEqual(PlanBuilderSheet.nextQuarterHour(after: at(10, 15), calendar: calendar), at(10, 30))
        XCTAssertEqual(PlanBuilderSheet.nextQuarterHour(after: at(10, 59), calendar: calendar), at(11, 0))
    }
}
