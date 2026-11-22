import XCTest
@testable import Plandit

final class PlanditStoreTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    @MainActor private struct QuotaExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            throw DevelopmentSocialEvidenceError.dailyLimit
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(candidates: [])
        }
    }

    @MainActor private struct AutoConfirmExtractor: PlaceExtracting {
        let candidate: PlaceCandidate

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            ExtractionResult(
                candidates: [candidate],
                autoConfirmedCandidateID: candidate.id
            )
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(
                candidates: [candidate],
                autoConfirmedCandidateID: candidate.id
            )
        }
    }

    @MainActor private struct CanonicalExtractor: PlaceExtracting {
        let canonicalURL: URL

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            ExtractionResult(canonicalURL: canonicalURL, candidates: [])
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(candidates: [])
        }
    }

    @MainActor private final class CountingExtractor: PlaceExtracting {
        private(set) var calls = 0

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            calls += 1
            return ExtractionResult(candidates: [])
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(candidates: [])
        }
    }

    @MainActor private func stop(_ place: Place, hour: Int, status: StopStatus = .upcoming) -> PlanStop {
        PlanStop(place: place, start: SampleData.at(hour), durationMinutes: 60, estimatedCost: 10, status: status)
    }

    @MainActor private func makeStore(
        stops: [PlanStop] = [],
        saved: [SavedPost] = [],
        date: Date = .now,
        storage: SnapshotStore? = nil,
        extractor: any PlaceExtracting = NoExtractor()
    ) -> PlanditStore {
        var plan = DayPlan(date: date, title: "Test day", budget: 60, stops: stops, legs: [])
        plan.legs = zip(plan.stops, plan.stops.dropFirst()).map { .estimate(from: $0, to: $1) }
        return PlanditStore(
            today: plan, saved: saved, profile: SampleData.profile,
            pastPlans: [], visited: [], extractor: extractor, storage: storage
        )
    }

    @MainActor private func threeStops() -> [PlanStop] {
        [stop(SampleData.hungarianPastry, hour: 9), stop(SampleData.met, hour: 11), stop(SampleData.highLine, hour: 14)]
    }

    @MainActor func testArriveMarksEarlierStopsDoneAndLaterOnesUpcoming() {
        let store = makeStore(stops: threeStops())
        store.arrive(at: store.today.stops[1].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .now, .upcoming])
    }

    @MainActor func testCompleteAdvancesToTheNextStop() {
        let store = makeStore(stops: threeStops())
        store.complete(store.today.stops[0].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .now, .upcoming])
        store.complete(store.today.stops[2].id)
        XCTAssertEqual(store.today.stops.map(\.status), [.done, .done, .done])
        XCTAssertTrue(store.today.isComplete)
    }

    @MainActor func testAddToTodayAppendsStopWithEstimatedLeg() {
        let post = SampleData.levainPost
        let store = makeStore(stops: [stop(SampleData.hungarianPastry, hour: 9)], saved: [post])
        let stopID = store.addToToday(post.id)
        XCTAssertNotNil(stopID)
        XCTAssertEqual(store.today.stops.count, 2)
        XCTAssertEqual(store.today.stops.last?.place.name, "Levain Bakery")
        XCTAssertEqual(store.today.stops.last?.estimatedCost, 6)
        XCTAssertEqual(store.today.legs.count, 1)
        XCTAssertTrue(store.isInToday(post))

        XCTAssertNil(store.addToToday(post.id), "adding the same post twice is a no-op")
        XCTAssertEqual(store.today.stops.count, 2)
    }

    @MainActor func testRemovingAMiddleStopRebuildsLegs() {
        let store = makeStore(stops: threeStops())
        store.removeStop(store.today.stops[1].id)
        XCTAssertEqual(store.today.stops.count, 2)
        XCTAssertEqual(store.today.legs.count, 1)
        XCTAssertEqual(store.today.legs.first?.fromStopID, store.today.stops[0].id)
        XCTAssertEqual(store.today.legs.first?.toStopID, store.today.stops[1].id)
    }

    @MainActor func testRollOverFilesYesterdaysPlanAndStartsTodayEmpty() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let store = makeStore(stops: threeStops(), date: yesterday)
        store.rollOverIfNeeded()
        XCTAssertTrue(store.today.stops.isEmpty)
        XCTAssertTrue(Calendar.current.isDateInToday(store.today.date))
        XCTAssertEqual(store.today.budget, SampleData.profile.defaultBudget)
        XCTAssertEqual(store.pastPlans.first?.title, "Test day")
        XCTAssertEqual(store.pastPlans.first?.stopCount, 3)
        XCTAssertEqual(store.visited.count, 3)
    }

    @MainActor func testRollOverLeavesTodayAlone() {
        let store = makeStore(stops: threeStops())
        store.rollOverIfNeeded()
        XCTAssertEqual(store.today.stops.count, 3)
        XCTAssertTrue(store.pastPlans.isEmpty)
    }

    @MainActor func testSnapshotRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanditStoreTests-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }

        let store = makeStore(stops: threeStops(), saved: [SampleData.levainPost, SampleData.failedPost], storage: storage)
        store.updateProfile { $0.homeBase = "Harlem" }
        store.flush()

        let loaded = try XCTUnwrap(storage.load())
        XCTAssertEqual(loaded.today.stops.map(\.id), store.today.stops.map(\.id))
        XCTAssertEqual(loaded.today.legs.count, 2)
        XCTAssertEqual(loaded.saved.map(\.id), store.saved.map(\.id))
        XCTAssertEqual(loaded.saved.map(\.status), [.ready, .failed])
        XCTAssertEqual(loaded.profile.homeBase, "Harlem")
    }

    @MainActor func testSavedPostDecodesSnapshotsFromBeforeExtractionFieldsWereAdded() throws {
        let original = SampleData.levainPost
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "canonicalURL")
        object.removeValue(forKey: "candidates")
        object.removeValue(forKey: "failureMessage")
        object.removeValue(forKey: "tags")

        let decoded = try JSONDecoder().decode(
            SavedPost.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.canonicalURL, original.url)
        XCTAssertEqual(decoded.tags, [])
        XCTAssertEqual(decoded.candidates, [])
        XCTAssertNil(decoded.failureMessage)
        XCTAssertEqual(decoded.place, original.place)
    }

    @MainActor func testCandidateMustBeConfirmedBeforeItCanEnterAPlan() {
        let candidate = PlaceCandidate(
            id: "mapkit:levain",
            place: SampleData.levain,
            confidence: .high,
            reason: "Matched the caption address"
        )
        let post = SavedPost(
            url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000100")!,
            canonicalURL: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000100")!,
            platform: .tiktok,
            savedAt: .now,
            status: .needsConfirmation,
            candidates: [candidate]
        )
        let store = makeStore(saved: [post])

        XCTAssertTrue(store.plannablePosts.isEmpty)
        XCTAssertTrue(store.buildPlan(postIDs: [post.id], start: SampleData.at(10), budget: 30, mode: PlanditStore.PlanMode.replace).stops.isEmpty)

        store.confirm(postID: post.id, candidateID: candidate.id)

        XCTAssertEqual(store.post(id: post.id)?.status, .ready)
        XCTAssertEqual(store.post(id: post.id)?.placeProviderID, candidate.id)
        XCTAssertEqual(store.plannablePosts.map { $0.id }, [post.id])
        XCTAssertEqual(
            store.buildPlan(postIDs: [post.id], start: SampleData.at(10), budget: 30, mode: PlanditStore.PlanMode.replace).stops.first?.place,
            candidate.place
        )
    }

    @MainActor func testExactAddressCandidateAutomaticallyBecomesMappable() async throws {
        let candidate = PlaceCandidate(
            id: "mapkit:kings-of-kobe",
            place: Place(
                name: "Kings of Kobe",
                category: .food,
                neighborhood: "Hell's Kitchen",
                address: "650 W 42nd St, New York, NY 10036",
                latitude: 40.7616,
                longitude: -73.9971
            ),
            confidence: .high,
            reason: "Exact caption address matched Apple Maps"
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanditAutoConfirm-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }
        let store = makeStore(storage: storage, extractor: AutoConfirmExtractor(candidate: candidate))
        let id = try store.save(
            url: URL(string: "https://www.tiktok.com/@creator/video/123")!
        )

        try await Task.sleep(for: .milliseconds(100))

        let post = try XCTUnwrap(store.post(id: id))
        XCTAssertEqual(post.status, .ready)
        XCTAssertEqual(post.place, candidate.place)
        XCTAssertEqual(post.placeProviderID, candidate.id)
        XCTAssertTrue(post.isMappable)
        XCTAssertTrue(post.candidates.isEmpty)
        XCTAssertEqual(storage.load()?.saved.first?.placeProviderID, candidate.id)

        let stopID = try XCTUnwrap(store.addToToday(id))
        let stop = try XCTUnwrap(store.stop(id: stopID))
        XCTAssertEqual(stop.place, candidate.place)
        XCTAssertEqual(stop.sourcePostID, id)
    }

    @MainActor func testResolvedCanonicalURLMergesShortAndFullLinks() async throws {
        let canonicalURL = URL(string: "https://www.tiktok.com/@creator/video/123")!
        let existing = SavedPost(
            url: canonicalURL,
            canonicalURL: canonicalURL,
            platform: .tiktok,
            savedAt: .now,
            status: .needsEvidence
        )
        let store = makeStore(
            saved: [existing],
            extractor: CanonicalExtractor(canonicalURL: canonicalURL)
        )

        _ = try store.save(url: URL(string: "https://www.tiktok.com/t/ABC")!)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.canonicalURL, canonicalURL)
    }

    @MainActor func testResolvedCanonicalURLPreservesExistingConfirmedSave() async throws {
        let canonicalURL = URL(string: "https://www.tiktok.com/@creator/video/123")!
        let existing = SavedPost(
            url: canonicalURL,
            canonicalURL: canonicalURL,
            platform: .tiktok,
            savedAt: .now,
            status: .ready,
            place: SampleData.levain,
            placeProviderID: "mapkit:levain"
        )
        let store = makeStore(
            saved: [existing],
            extractor: CanonicalExtractor(canonicalURL: canonicalURL)
        )

        _ = try store.save(url: URL(string: "https://www.tiktok.com/t/ABC")!)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(store.saved.map(\.id), [existing.id])
        XCTAssertEqual(store.saved.first?.place, existing.place)
        XCTAssertEqual(store.saved.first?.placeProviderID, existing.placeProviderID)
        XCTAssertTrue(store.saved.first?.isMappable == true)
        XCTAssertEqual(store.saved.first, existing)
    }

    @MainActor func testResolvedCanonicalURLDoesNotDeleteOtherConfirmedSaves() async throws {
        let canonicalURL = URL(string: "https://www.tiktok.com/@creator/video/123")!
        let first = SavedPost(
            url: canonicalURL,
            canonicalURL: canonicalURL,
            platform: .tiktok,
            savedAt: .now,
            status: .ready,
            place: SampleData.levain,
            placeProviderID: "mapkit:levain"
        )
        let second = SavedPost(
            url: canonicalURL,
            canonicalURL: canonicalURL,
            platform: .tiktok,
            savedAt: .now,
            status: .ready,
            place: SampleData.losTacos,
            placeProviderID: "mapkit:los-tacos"
        )
        let store = makeStore(
            saved: [first, second],
            extractor: CanonicalExtractor(canonicalURL: canonicalURL)
        )

        _ = try store.save(url: URL(string: "https://www.tiktok.com/t/ABC")!)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(Set(store.saved.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(Set(store.saved.compactMap(\.placeProviderID)), Set(["mapkit:levain", "mapkit:los-tacos"]))
    }

    @MainActor func testIngestPendingSharesSavesEachLinkOnce() {
        let store = makeStore()
        let url = URL(string: "https://www.tiktok.com/@someone/video/7400000000000000099")!
        ShareInbox.enqueue(IncomingShare(url: url, sharedText: "caption"))
        ShareInbox.enqueue(IncomingShare(url: url))

        let ids = store.ingestPendingShares()
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.caption, "caption")
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testResharingUnresolvedLinkRetriesExtraction() async throws {
        let url = URL(string: "https://www.instagram.com/reel/DHZYjjnPKez")!
        let existing = SavedPost(
            url: url,
            canonicalURL: url,
            platform: .instagram,
            savedAt: .now,
            status: .needsEvidence,
            failureMessage: "We couldn't find the place."
        )
        let extractor = CountingExtractor()
        let store = makeStore(saved: [existing], extractor: extractor)

        let id = try store.save(url: url)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(id, existing.id)
        XCTAssertEqual(extractor.calls, 1)
        XCTAssertNil(store.post(id: id)?.failureMessage)
    }

    @MainActor func testPendingSnapshotCannotOverwriteAnAcknowledgedShare() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanditShareRace-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }
        let store = makeStore(storage: storage)
        let sharedURL = URL(string: "https://www.tiktok.com/@someone/video/7400000000000000101")!

        store.updateProfile { $0.homeBase = "Brooklyn" }
        ShareInbox.enqueue(IncomingShare(url: sharedURL))
        XCTAssertEqual(store.ingestPendingShares().count, 1)
        try await Task.sleep(for: .milliseconds(350))

        let loaded = try XCTUnwrap(storage.load())
        XCTAssertEqual(loaded.saved.map(\.url), [sharedURL])
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testDailyUrlLimitOffersEvidenceFallback() async throws {
        let store = makeStore(extractor: QuotaExtractor())
        let id = try store.save(
            url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000102")!
        )

        try await Task.sleep(for: .milliseconds(100))

        let post = try XCTUnwrap(store.post(id: id))
        XCTAssertEqual(post.status, .needsEvidence)
        XCTAssertEqual(
            post.failureMessage,
            "Automatic imports are paused for today. Add the place name or address below, or use the video instead."
        )
    }

    // MARK: - Suggested plans (SP-10, SP-11)

    @MainActor private final class EventLog {
        var events: [UsageEvent] = []
    }

    /// Three places a block apart in Chelsea: one closes at 3 PM, so starting later changes the plan.
    @MainActor private func suggestionPosts() -> [SavedPost] {
        func post(_ name: String, north: Double, category: PlaceCategory, hours: String?, cost: Double) -> SavedPost {
            SavedPost(
                url: URL(string: "https://www.tiktok.com/@test/video/\(name.count)")!, platform: .tiktok,
                savedAt: SampleData.daysAgo(2), status: .ready,
                place: Place(name: name, category: category, neighborhood: "Chelsea", address: "\(name) St",
                             latitude: 40.7424 + north, longitude: -74.0060, hours: hours),
                estimatedCost: cost
            )
        }
        return [
            post("Lunch counter", north: 0, category: .food, hours: "Open until 3 PM", cost: 12),
            post("Gallery", north: 0.002, category: .culture, hours: nil, cost: 0),
            post("Bookshop", north: 0.004, category: .shopping, hours: "Open until 9 PM", cost: 8),
        ]
    }

    @MainActor private func suggestionStore(_ posts: [SavedPost], start: Date) -> (PlanditStore, EventLog) {
        let log = EventLog()
        let store = PlanditStore(
            today: .empty(for: .now, budget: 60), saved: posts, profile: SampleData.profile,
            pastPlans: [], visited: [], extractor: NoExtractor(), storage: nil,
            events: { log.events.append($0) }
        )
        store.suggestionStart = { start }
        store.refreshSuggestions()
        return (store, log)
    }

    @MainActor func testUseSuggestionMatchesPreview() throws {
        let start = SampleData.at(14)
        let (store, log) = suggestionStore(suggestionPosts(), start: start)
        let suggestion = try XCTUnwrap(store.suggestions.first)

        let preview = store.previewPlan(postIDs: suggestion.postIDs, start: start, budget: store.profile.defaultBudget,
                                        mode: .replace, end: start.addingTimeInterval(4 * 3600))
        XCTAssertTrue(preview.isSamePlan(as: suggestion.outcome), "the card shows what the planner would build")

        XCTAssertEqual(store.useSuggestion(suggestion), .applied)
        XCTAssertEqual(store.today.stops.map(\.sourcePostID), suggestion.postIDs, "same stops in the same order")
        XCTAssertEqual(store.today.stops.map(\.start), suggestion.outcome.stops.map(\.start), "same times")
        XCTAssertEqual(store.today.totalCost, suggestion.outcome.cost, accuracy: 0.005, "same cost")
        XCTAssertEqual(store.today.budget, store.profile.defaultBudget)
        XCTAssertEqual(store.undo?.message, "Made a new plan", "the same undo step as building a plan by hand")
        XCTAssertEqual(log.events, [.planBuilt, .suggestionUsed])
        XCTAssertTrue(store.suggestions.isEmpty, "Today has a plan now")
        XCTAssertNil(store.suggestionNotice)

        store.undoLastChange()
        XCTAssertTrue(store.today.stops.isEmpty, "Undo empties Today again")
        XCTAssertEqual(store.suggestions.first, suggestion, "and the same cards come back")
    }

    @MainActor func testUseSuggestionStale() throws {
        let posts = suggestionPosts()
        let lunch = posts[0].id
        let (store, log) = suggestionStore(posts, start: SampleData.at(14))
        let shown = try XCTUnwrap(store.suggestions.first { $0.postIDs.contains(lunch) })

        // Later, the lunch counter (open until 3 PM) has closed for a new plan.
        store.suggestionStart = { SampleData.at(15) }
        XCTAssertEqual(store.useSuggestion(shown), .stale)
        XCTAssertTrue(store.today.stops.isEmpty, "a stale card doesn't change Today")
        XCTAssertNil(store.undo)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(store.suggestionNotice, "It's later now, so these plans changed.")
        XCTAssertFalse(store.suggestions.isEmpty, "the cards refresh")
        XCTAssertFalse(store.suggestions.contains { $0.postIDs.contains(lunch) }, "without the place that closed")

        // The time slot moved, same places: still not applied silently.
        let current = try XCTUnwrap(store.suggestions.first)
        store.suggestionStart = { SampleData.at(15, 15) }
        XCTAssertEqual(store.useSuggestion(current), .stale)
        XCTAssertTrue(store.today.stops.isEmpty)

        // A fresh card applies, and the message goes.
        let fresh = try XCTUnwrap(store.suggestions.first)
        XCTAssertEqual(store.useSuggestion(fresh), .applied)
        XCTAssertNil(store.suggestionNotice)
    }

    @MainActor func testSuggestionsStayPutWithinATimeSlotAndOnlyForAnEmptyToday() throws {
        let start = SampleData.at(14)
        let (store, _) = suggestionStore(suggestionPosts(), start: start)
        let first = store.suggestions
        XCTAssertFalse(first.isEmpty)
        store.refreshSuggestions()
        XCTAssertEqual(store.suggestions, first, "same saves, settings and slot: the same cards")

        store.updateProfile { $0.defaultBudget = 0 }
        XCTAssertTrue(store.suggestions.isEmpty, "a budget change recomputes them")
        store.updateProfile { $0.defaultBudget = 60 }
        XCTAssertEqual(store.suggestions, first)

        _ = store.addToToday(store.plannablePosts[1].id)
        XCTAssertTrue(store.suggestions.isEmpty, "no suggestions once Today has a plan")
    }

    @MainActor func testChangedMessageGoesWhenTheTimeSlotMovesOn() throws {
        let posts = suggestionPosts()
        let (store, _) = suggestionStore(posts, start: SampleData.at(14))
        let shown = try XCTUnwrap(store.suggestions.first { $0.postIDs.contains(posts[0].id) })

        store.suggestionStart = { SampleData.at(15) }
        XCTAssertEqual(store.useSuggestion(shown), .stale)
        XCTAssertNotNil(store.suggestionNotice)

        store.suggestionStart = { SampleData.at(15, 10) }
        store.refreshSuggestions()
        XCTAssertNotNil(store.suggestionNotice, "the same 15-minute slot: the message stays with the cards it explains")

        store.suggestionStart = { SampleData.at(15, 15) }
        store.refreshSuggestions()
        XCTAssertNil(store.suggestionNotice, "the next slot: the message doesn't linger")
    }

    // MARK: - Places done today (SP-9)

    @MainActor func testPlaceDoneTodayIsNotSuggestedAfterItLeavesThePlan() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlanditStoreTests-\(UUID().uuidString).json")
        let storage = SnapshotStore(url: url)
        defer { storage.reset() }
        let posts = suggestionPosts()

        let store = PlanditStore(
            today: .empty(for: .now, budget: 60), saved: posts, profile: SampleData.profile,
            pastPlans: [], visited: [], extractor: NoExtractor(), storage: storage
        )
        store.suggestionStart = { SampleData.at(14) }
        store.refreshSuggestions()
        XCTAssertEqual(store.useSuggestion(try XCTUnwrap(store.suggestions.first)), .applied)

        // Done at the first stop, then every stop taken out of the plan.
        let first = store.today.stops[0]
        let done = try XCTUnwrap(first.sourcePostID)
        store.complete(first.id)
        for stop in store.today.stops { store.removeStop(stop.id) }
        XCTAssertTrue(store.today.stops.isEmpty)

        XCTAssertFalse(store.suggestions.isEmpty, "the places not done yet are still suggested")
        XCTAssertFalse(store.suggestions.contains { $0.postIDs.contains(done) }, "the place done today isn't")
        XCTAssertEqual(store.postsDoneToday, [done])

        // After a restart, from the files on the phone.
        store.flush()
        let reloaded = PlanditStore(snapshot: try XCTUnwrap(storage.load()), extractor: NoExtractor(), storage: storage)
        reloaded.suggestionStart = { SampleData.at(14) }
        reloaded.refreshSuggestions()
        XCTAssertEqual(reloaded.postsDoneToday, [done])
        XCTAssertFalse(reloaded.suggestions.isEmpty)
        XCTAssertFalse(reloaded.suggestions.contains { $0.postIDs.contains(done) }, "still skipped after a restart")
        // Kept beside the snapshot, not in it: the synced copy's shape doesn't change.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: ["saved", "today", "profile", "pastPlans", "visited", "sharedLink"]),
                      "\(object.keys.sorted())")

        // A new day starts with nothing done.
        reloaded.rollOverIfNeeded(now: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: .now)))
        XCTAssertTrue(reloaded.postsDoneToday.isEmpty)
        reloaded.flush()
        let nextDay = PlanditStore(snapshot: try XCTUnwrap(storage.load()), extractor: NoExtractor(), storage: storage)
        XCTAssertTrue(nextDay.postsDoneToday.isEmpty)
    }

    @MainActor func testUndoingDoneHereMeansNotDone() throws {
        let (store, _) = suggestionStore(suggestionPosts(), start: SampleData.at(14))
        XCTAssertEqual(store.useSuggestion(try XCTUnwrap(store.suggestions.first)), .applied)
        let first = store.today.stops[0]
        store.complete(first.id)
        XCTAssertEqual(store.postsDoneToday, [try XCTUnwrap(first.sourcePostID)])
        store.leave(first.id)
        XCTAssertTrue(store.postsDoneToday.isEmpty, "back to planned: not done after all")
    }
}
