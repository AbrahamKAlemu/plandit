import CoreLocation
import Foundation
import Observation

private struct SavedPlacePersistenceError: LocalizedError {
    var errorDescription: String? {
        "We couldn't save that change. Try again."
    }
}

/// App-wide state: today's plan, saved posts, and the profile.
/// Persisted locally after every change; backed by sample data on first launch.
@Observable
@MainActor
final class PlanditStore {
    var today: DayPlan
    var saved: [SavedPost]
    var profile: UserProfile
    var pastPlans: [PastPlan]
    var visited: [Place]
    var savedErrorMessage: String?
    /// Real walking or driving geometry per leg, filled in by `loadRoutes()`.
    private(set) var legPaths: [UUID: [CLLocationCoordinate2D]] = [:]
    /// The plan shared as a link (plandit.app/p/<slug>). It follows the plan: edits update the page.
    private(set) var sharedLink: SharedLink?
    /// Publishes links; nil when signed out of the server (the local test account).
    @ObservationIgnored var sharing: (any PlanSharing)?
    /// A page update waiting to go out (`scheduleShareUpdate`); one being sent isn't kept here.
    @ObservationIgnored private var pendingShareUpdate: Task<Void, Never>?
    /// A request to the page is out; the next one waits its turn (`inTurn`).
    @ObservationIgnored private var isSendingToPage = false
    @ObservationIgnored private var pageTurnWaiters: [CheckedContinuation<Void, Never>] = []
    /// How many Share plan and Stop sharing calls are talking to the server. Changes made meanwhile
    /// wait until the last one ends: it decides whether there's still a page to update.
    @ObservationIgnored private var linkOperations = 0
    @ObservationIgnored private var lastPublished: SharedPlanPayload?
    /// Friends' answers on the link; nil when signed out of the server (the local test account).
    @ObservationIgnored var answerClient: (any ShareAnswersFetching)?
    /// Friends' answers on `answersSlug`'s page, as last fetched. Memory only (GS-7).
    private(set) var fetchedAnswers: [ShareAnswer] = []
    private var answersSlug: String?
    /// The link and time the last refresh that counts went out, set as it starts: Today appearing
    /// again within 10 s doesn't ask again, and neither does Today while the app's launch refresh is
    /// still out. A refresh that fails puts back what was there, so the next one tries again.
    @ObservationIgnored private var answersAsked: (slug: String, at: Date)?
    /// Goes up with each change to the answers made here (removing one, stopping sharing), so a
    /// refresh that was out meanwhile can't bring back what it changed (GV-7).
    @ObservationIgnored private var answersChanges = 0
    /// The last change to today's plan, so it can be undone: "The Met is done · Undo".
    private(set) var undo: PlanUndo?
    /// The "Ask friends what works" link (plandit.app/g/<slug>), kept in the snapshot.
    private(set) var planRequest: PlanRequestLink?
    /// Makes and reads those links; nil when signed out of the server (the local test account).
    @ObservationIgnored var requestClient: (any PlanRequesting)?
    /// `planRequest` with friends' answers, as last fetched. Memory only: answers are never saved on the phone.
    private(set) var fetchedRequest: PlanRequest?
    /// The answers couldn't be read and none were read before (after a relaunch, say): there's
    /// nothing to plan from until they are.
    private(set) var requestFetchFailed = false
    /// The link and time the last refresh that counts went out, as for shared plans' answers.
    @ObservationIgnored private var requestAsked: (slug: String, at: Date)?
    /// Goes up with each change made here (a new link, a removed answer, closing, building), so a
    /// refresh that was out meanwhile can't bring back what it changed.
    @ObservationIgnored private var requestChanges = 0

    /// Computed from real past plans and visited places; never sample numbers.
    var stats: UserStats { UserStats.compute(pastPlans: pastPlans, visited: visited, placesSaved: saved.count) }

    /// Called after every successful local write with what was written. The sync coordinator hooks in here.
    @ObservationIgnored var onChange: ((StoreSnapshot) -> Void)?
    /// Usage events for the metrics API. Injected so tests can capture them; nil drops them.
    @ObservationIgnored var events: ((UsageEvent) -> Void)?

    @ObservationIgnored private let extractor: any PlaceExtracting
    @ObservationIgnored private let videoExtractor: any VideoEvidenceReading
    /// Where shared videos wait to be read (`TemporaryMedia/` in the App Group container).
    @ObservationIgnored private let mediaStore: TemporaryMediaStore
    /// How long a failed lookup waits before its one automatic retry (PRC-3).
    @ObservationIgnored private let extractionRetryDelay: Duration
    /// When each post started looking for its place, for the "Still looking" line (PRC-2).
    @ObservationIgnored private(set) var findingStartedAt: [UUID: Date] = [:]
    /// Goes up each time a place is added to Saved, by an exact match or a pick: the success haptic (PRC-7).
    private(set) var placesAdded = 0
    @ObservationIgnored private let routes: any RouteProviding
    /// Apple Maps answers by mode and place pair, so a leg's options load once.
    @ObservationIgnored private var liveRoutes: [String: RouteInfo] = [:]
    @ObservationIgnored private let storage: SnapshotStore?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Posts whose extraction or evidence lookup is still running; never started twice.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Video posts being read on this phone right now.
    @ObservationIgnored private var readingVideos: Set<UUID> = []
    /// Closed with its account session: no write reaches the file, no hook fires.
    @ObservationIgnored private(set) var isClosed = false

    init(
        today: DayPlan,
        saved: [SavedPost],
        profile: UserProfile,
        pastPlans: [PastPlan],
        visited: [Place],
        extractor: any PlaceExtracting = FixturePlaceExtractor(),
        storage: SnapshotStore? = nil,
        videoExtractor: any VideoEvidenceReading = VideoEvidenceExtractor(),
        mediaStore: TemporaryMediaStore = TemporaryMediaStore(),
        extractionRetryDelay: Duration = .seconds(2),
        events: ((UsageEvent) -> Void)? = nil,
        routes: any RouteProviding = RouteService()
    ) {
        self.routes = routes
        self.today = today
        self.saved = saved
        self.profile = profile
        self.pastPlans = pastPlans
        self.visited = visited
        self.extractor = extractor
        self.storage = storage
        self.videoExtractor = videoExtractor
        self.mediaStore = mediaStore
        self.extractionRetryDelay = extractionRetryDelay
        self.events = events
        doneToday = storage?.loadDoneToday()
        resumeInterruptedLookups()
    }

    /// An account's store from its snapshot (local file or cloud copy).
    convenience init(
        snapshot: StoreSnapshot,
        extractor: any PlaceExtracting = FixturePlaceExtractor(),
        storage: SnapshotStore? = nil,
        events: ((UsageEvent) -> Void)? = nil
    ) {
        self.init(
            today: snapshot.today,
            saved: snapshot.saved,
            profile: snapshot.profile,
            pastPlans: snapshot.pastPlans,
            visited: snapshot.visited,
            extractor: extractor,
            storage: storage,
            events: events
        )
        sharedLink = snapshot.sharedLink
        planRequest = snapshot.planRequest
    }

    /// Swaps in another copy of this account's data (the server's, after sync) and writes it locally.
    /// Routes and leg paths are rebuilt; the day is rolled over if that copy is from an earlier date.
    func replace(with snapshot: StoreSnapshot) {
        pendingSave?.cancel()
        pendingSave = nil
        today = snapshot.today
        saved = snapshot.saved
        profile = snapshot.profile
        pastPlans = snapshot.pastPlans
        visited = snapshot.visited
        sharedLink = snapshot.sharedLink
        planRequest = snapshot.planRequest
        legPaths = [:]
        persistNow()
        rollOverIfNeeded()
        resumeInterruptedLookups(convertsVideos: false)
        Task { await loadRoutes() }
    }

    /// Posts left looking for their place (the app quit, or another phone's copy arrived): a link
    /// looks again. At launch, a video asks to be shared again, since its copy may be gone (PRC-8).
    /// After a sync it's left looking: this phone may be reading it, or the phone that sent it may.
    private func resumeInterruptedLookups(convertsVideos: Bool = true) {
        for post in saved where post.status == .processing {
            if post.platform == .video {
                guard convertsVideos, !readingVideos.contains(post.id), !inFlight.contains(post.id) else { continue }
                updateAndPersist(post.id) {
                    $0.status = .needsEvidence
                    $0.failureMessage = Self.shareVideoAgainMessage
                }
            } else {
                startExtraction(post.id)
            }
        }
    }

    static let shareVideoAgainMessage = "Share the video again or add the place's name."
    /// After the automatic retry also failed (PRC-3).
    static let lookupFailedMessage = "The search didn't finish. Try again, or add the place's name or address."

    /// Detaches the store from its account: pending writes are dropped and later ones (a late
    /// extraction result, say) never touch the file or the hooks.
    func close() {
        cancelPendingSave()
        isClosed = true
        onChange = nil
        events = nil
    }

    /// What the user left last time, rolled over to today; the sample data on first launch
    /// or when launched with `-resetData`.
    static func load(storage: SnapshotStore = .default, extractor: any PlaceExtracting = launchExtractor()) -> PlanditStore {
        if CommandLine.arguments.contains("-resetData") { storage.reset() }
#if DEBUG
        if CommandLine.arguments.contains("-seedSuggestions") {
            storage.reset()
            return PlanditStore(
                today: .empty(for: .now, budget: SampleData.profile.defaultBudget), saved: SuggestionSeed.savedPosts,
                profile: SampleData.profile, pastPlans: [], visited: [], extractor: extractor, storage: storage
            )
        }
#endif
        let resetsSavedData = CommandLine.arguments.contains("-resetSavedData")
        guard let snapshot = storage.load() else {
            let store = sample(
                storage: storage,
                extractor: extractor,
                saved: resetsSavedData ? [] : SampleData.savedPosts
            )
            if resetsSavedData { store.persistNow() }
            return store
        }
        let store = PlanditStore(
            today: snapshot.today,
            saved: resetsSavedData ? [] : snapshot.saved,
            profile: snapshot.profile,
            pastPlans: snapshot.pastPlans,
            visited: snapshot.visited,
            extractor: extractor,
            storage: storage
        )
        store.sharedLink = snapshot.sharedLink
        store.planRequest = snapshot.planRequest
        store.rollOverIfNeeded()
        if resetsSavedData { store.persistNow() }
        return store
    }

    static func sample(
        storage: SnapshotStore? = nil,
        extractor: any PlaceExtracting = FixturePlaceExtractor(),
        saved: [SavedPost] = SampleData.savedPosts
    ) -> PlanditStore {
        PlanditStore(
            today: SampleData.dayPlan,
            saved: saved,
            profile: SampleData.profile,
            pastPlans: SampleData.pastPlans,
            visited: SampleData.visitedPlaces,
            extractor: extractor,
            storage: storage
        )
    }

    // MARK: - Lookup

    func stop(id: UUID) -> PlanStop? { today.stop(id: id) }

    func stopIndex(id: UUID) -> Int? { today.stops.firstIndex { $0.id == id } }

    func stopNumber(id: UUID) -> Int? { stopIndex(id: id).map { $0 + 1 } }

    func post(id: UUID?) -> SavedPost? {
        guard let id else { return nil }
        return saved.first { $0.id == id }
    }

    func isInToday(_ post: SavedPost) -> Bool {
        today.stops.contains { $0.sourcePostID == post.id }
    }

    /// Walking or driving path if loaded, otherwise a straight line (MapKit has no transit geometry).
    func path(for leg: TravelLeg) -> [CLLocationCoordinate2D] {
        if let path = legPaths[leg.id] { return path }
        guard let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return [] }
        return [from.place.coordinate, to.place.coordinate]
    }

    // MARK: - Routes

    func loadRoutes() async {
        for leg in today.legs where !leg.mode.isTransit && legPaths[leg.id] == nil {
            guard let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { continue }
            let path = await liveRoute(leg.mode, from: from.place, to: to.place)?.path
            // The leg may have changed mode while Apple Maps answered.
            guard today.legs.first(where: { $0.id == leg.id })?.mode == leg.mode else { continue }
            legPaths[leg.id] = path ?? [from.place.coordinate, to.place.coordinate]
        }
    }

    private func liveRoute(_ mode: TravelMode, from: Place, to: Place) async -> RouteInfo? {
        let key = Self.routeKey(mode, from: from, to: to)
        if let cached = liveRoutes[key] { return cached }
        let info = await routes.route(mode, from: from.coordinate, to: to.coordinate)
        if let info { liveRoutes[key] = info }
        return info
    }

    private static func routeKey(_ mode: TravelMode, from: Place, to: Place) -> String {
        "\(mode.rawValue)|\(from.latitude),\(from.longitude)|\(to.latitude),\(to.longitude)"
    }

    // MARK: - Getting between stops (walk, subway or drive)

    /// One way to make a trip, with its time and cost. `isLive` when the time came from Apple Maps.
    struct TravelOption: Identifiable, Equatable {
        var leg: TravelLeg
        var isLive: Bool
        var id: TravelMode { leg.mode }
    }

    /// Walk, subway and drive for a leg, using Apple Maps times already loaded and estimates otherwise.
    /// A trip planned another way (a bus) keeps that way among them.
    func travelOptions(forLeg id: UUID) -> [TravelOption] {
        guard let leg = today.legs.first(where: { $0.id == id }),
              let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return [] }
        return Self.travelModes(for: leg).map { mode in
            let live = liveRoutes[Self.routeKey(mode, from: from.place, to: to.place)]
            return TravelOption(leg: Self.leg(mode, live: live, replacing: leg, from: from.place, to: to.place), isLive: live != nil)
        }
    }

    /// Asks Apple Maps for all three ways of making this trip.
    func loadTravelOptions(forLeg id: UUID) async {
        guard let leg = today.legs.first(where: { $0.id == id }),
              let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return }
        for mode in Self.travelModes(for: leg) {
            _ = await liveRoute(mode, from: from.place, to: to.place)
        }
    }

    private static func travelModes(for leg: TravelLeg) -> [TravelMode] {
        TravelMode.allCases.filter { TravelMode.choices.contains($0) || $0 == leg.mode }
    }

    /// The day if this trip were made this way: later stops move with the new travel time.
    func previewTravel(_ option: TravelOption) -> DayPlan {
        var plan = today
        plan.setLeg(option.leg)
        return plan
    }

    /// Makes this trip this way and moves the rest of the day to match.
    func chooseTravel(_ option: TravelOption) {
        guard today.legs.contains(where: { $0.id == option.leg.id }) else { return }
        forgetUndo()
        today.setLeg(option.leg)
        legPaths[option.leg.id] = nil
        persist()
        Task { await loadRoutes() }
    }

    /// What the day would look like with this stop's time changed, before saving it.
    func previewTime(ofStop id: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool) -> DayPlan {
        var plan = today
        plan.setTime(ofStop: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops)
        return plan
    }

    func setTime(ofStop id: UUID, start: Date, durationMinutes: Int, moveLaterStops: Bool) {
        if let stop = stop(id: id) { remember("Changed \(stop.place.name)'s time") }
        today.setTime(ofStop: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops)
        persist()
    }

    /// Every trip still ahead goes this way: "Drive everywhere", "Take the subway". Trips already
    /// made this way keep their time (only marked as the user's pick), so the timeline doesn't
    /// jump to Apple Maps' newer times; only trips that change how they're made get a new time.
    func chooseTravelForRestOfDay(_ mode: TravelMode) {
        forgetUndo()
        for (index, leg) in today.legs.enumerated() where today.state(of: leg) != .completed {
            if leg.mode == mode {
                today.legs[index].isChosen = true
                continue
            }
            guard let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { continue }
            let live = liveRoutes[Self.routeKey(mode, from: from.place, to: to.place)]
            today.setLeg(Self.leg(mode, live: live, replacing: leg, from: from.place, to: to.place))
            legPaths[leg.id] = nil
        }
        persist()
        Task { await loadRoutes() }
    }

    /// A leg by `mode` with the same id, so the map and timeline keep their place.
    private static func leg(_ mode: TravelMode, live: RouteInfo?, replacing leg: TravelLeg, from: Place, to: Place) -> TravelLeg {
        let miles = live?.miles ?? TravelLeg.streetMiles(from: from, to: to)
        var new = TravelLeg.estimate(mode, miles: miles, fromStopID: leg.fromStopID, toStopID: leg.toStopID)
        // Apple Maps' driving time doesn't include waiting for a taxi or rideshare.
        if let live { new.minutes = live.minutes + (mode == .drive ? TravelLeg.pickupMinutes : 0) }
        new.id = leg.id
        new.isChosen = true
        return new
    }

    /// Directions for the trip into this stop go by the way that trip is planned.
    func travelMode(into stopID: UUID) -> TravelMode {
        today.legs.first { $0.toStopID == stopID }?.mode ?? .walk
    }

    // MARK: - Costs

    /// The reference price for a stop: what its post said, or what this kind of place usually costs.
    func priceGuide(for stop: PlanStop) -> PriceGuide {
        post(id: stop.sourcePostID)?.postedPrice ?? .typical(stop.place.category)
    }

    /// The user's own number for this stop. Replaces any items they listed.
    func setCost(_ amount: Double, forStop id: UUID) {
        guard let index = stopIndex(id: id) else { return }
        today.stops[index].estimatedCost = max(0, amount)
        today.stops[index].costItems = []
        today.stops[index].costIsCustom = true
        persist()
    }

    /// What the user will pay for here, item by item. The stop's cost becomes their total;
    /// removing the last item goes back to the estimate.
    func setCostItems(_ items: [CostItem], forStop id: UUID) {
        guard let index = stopIndex(id: id) else { return }
        if items.isEmpty {
            resetCost(forStop: id)
            return
        }
        today.stops[index].costItems = items
        today.stops[index].estimatedCost = items.total
        today.stops[index].costIsCustom = true
        persist()
    }

    /// Back to the user's price for the saved place, the post's, or the typical price.
    func resetCost(forStop id: UUID) {
        guard let index = stopIndex(id: id) else { return }
        let stop = today.stops[index]
        today.stops[index].estimatedCost = post(id: stop.sourcePostID)?.plannedCost ?? priceGuide(for: stop).estimate
        today.stops[index].costItems = []
        today.stops[index].costIsCustom = false
        persist()
    }

    /// The user's price for a saved place, used whenever it's planned. nil goes back to the post's or typical price.
    /// Stops already planned from it follow, unless the user set that stop's cost separately.
    @discardableResult
    func setUserCost(_ amount: Double?, forPost id: UUID) -> Bool {
        guard updateAndPersist(id, mutation: { $0.userCost = amount.map { max(0, $0) } }) else { return false }
        guard let post = post(id: id), let cost = post.plannedCost else { return true }
        var changed = false
        for index in today.stops.indices where today.stops[index].sourcePostID == id && !today.stops[index].costIsCustom {
            today.stops[index].estimatedCost = cost
            changed = true
        }
        if changed { persist() }
        return true
    }

    func setBudget(_ amount: Double) {
        today.budget = max(0, amount)
        persist()
    }

    /// Costs for the day that aren't one stop: snacks, a ride home.
    func setExtras(_ items: [CostItem]) {
        today.extras = items
        persist()
    }

    // MARK: - Day rollover

    /// A plan belongs to one date. On the first launch of a new day, file the old plan under
    /// recent plans and start today empty with the default budget.
    func rollOverIfNeeded(now: Date = .now) {
        guard !Calendar.current.isDate(today.date, inSameDayAs: now) else { return }
        if !today.stops.isEmpty {
            pastPlans.insert(
                PastPlan(
                    title: today.title,
                    date: today.date,
                    stopCount: today.stops.count,
                    cost: today.totalCost,
                    budget: today.budget,
                    walkingMiles: today.walkingMiles,
                    fares: today.faresCost
                ),
                at: 0
            )
            for place in today.stops.map(\.place) where !visited.contains(where: { $0.name == place.name }) {
                visited.append(place)
            }
        }
        today = .empty(for: now, budget: profile.defaultBudget)
        legPaths = [:]
        persist()
    }

    // MARK: - Saved posts

    /// Pulls in anything the share extension queued while the app was in the background.
    /// Returns the ids of the posts those shares map to, newest last.
    /// Links and videos alike: each share is acknowledged only once its post is saved, so a share
    /// is never lost and never imported twice. Every lookup starts at once and runs side by side.
    @discardableResult
    func ingestPendingShares() -> [UUID] {
        var ids: [UUID] = []
        for share in ShareInbox.pending() {
            do {
                if let fileName = share.videoFileName {
                    // The post takes the share's id, so a share that comes back (the app quit
                    // before acknowledging it) finds its post instead of making a second one.
                    if post(id: share.id) == nil {
                        ids.append(try importSharedVideo(id: share.id, fileURL: mediaStore.file(named: fileName), receivedAt: share.receivedAt))
                    } else {
                        if let leftover = mediaStore.file(named: fileName) { try? mediaStore.remove(leftover) }
                        if !ids.contains(share.id) { ids.append(share.id) }
                    }
                } else if let url = share.url {
                    let id = try save(url: url, sharedText: share.sharedText, savedAt: share.receivedAt)
                    if !ids.contains(id) { ids.append(id) }
                }
                ShareInbox.acknowledge(share.id)
            } catch {
                savedErrorMessage = error.localizedDescription
            }
        }
        return ids
    }

    /// A video from the share sheet becomes a post right away, in `processing`, and is read on this
    /// phone in the background. If it can't be read (or it's gone), the post stays and asks for the
    /// place's name instead of disappearing (PRC-4). The file is deleted once it's read; until then
    /// it's in `Reading/`, where the 24-hour cleanup can't reach it.
    @discardableResult
    func importSharedVideo(id: UUID = UUID(), fileURL: URL?, receivedAt: Date = .now) throws -> UUID {
        let sourceURL = URL(string: "plandit-video://\(id.uuidString)")!
        let file = fileURL.flatMap { try? mediaStore.claimForReading($0) }
        let post = SavedPost(
            id: id,
            url: sourceURL,
            canonicalURL: sourceURL,
            platform: .video,
            savedAt: receivedAt,
            status: file == nil ? .needsEvidence : .processing,
            failureMessage: file == nil ? Self.shareVideoAgainMessage : nil
        )
        var updated = saved
        updated.insert(post, at: 0)
        do {
            try persistSaved(updated)
        } catch {
            // Not saved, so the share stays queued: put its video back for the next try.
            if let file, let fileURL { try? FileManager.default.moveItem(at: file, to: fileURL) }
            throw error
        }
        saved = updated
        events?(.linkSaved)
        if let file {
            readingVideos.insert(id)
            findingStartedAt[id] = .now
            Task { await readSharedVideo(postID: id, fileURL: file) }
        }
        return id
    }

    private func readSharedVideo(postID: UUID, fileURL: URL) async {
        defer {
            readingVideos.remove(postID)
            try? mediaStore.remove(fileURL)
        }
        do {
            try await applyVideoEvidence(postID: postID, fileURL: fileURL)
        } catch {
            updateAndPersist(postID) {
                $0.status = .needsEvidence
                $0.failureMessage = Self.videoFailureMessage(error)
            }
        }
    }

    /// What a video post says when its video couldn't be read: our own reasons as they are; a
    /// system error (the file vanished, say) never reaches the synced post, it asks for the video again.
    private static func videoFailureMessage(_ error: any Error) -> String {
        (error as? VideoEvidenceError)?.errorDescription ?? shareVideoAgainMessage
    }

    /// `savedAt` is when it was shared, for a link from the share sheet; now, for one added in the app.
    @discardableResult
    func save(url: URL, sharedText: String? = nil, savedAt: Date = .now) throws -> UUID {
        let supported = try SupportedSocialURL(url)
        if let index = saved.firstIndex(where: { $0.canonicalURL == supported.canonicalURL }) {
            let existing = saved[index]
            guard existing.status == .failed || existing.status == .needsEvidence else {
                return existing.id
            }
            var updated = saved
            updated[index].status = .processing
            updated[index].failureMessage = nil
            try persistSaved(updated)
            saved = updated
            startExtraction(existing.id)
            return existing.id
        }
        let post = SavedPost(
            url: url,
            canonicalURL: supported.canonicalURL,
            platform: supported.platform,
            // A TikTok link names its creator, so the post can show them while it waits (PRC-2).
            creatorHandle: supported.canonicalURL.pathComponents.first { $0.hasPrefix("@") && $0.count > 1 },
            caption: sharedText,
            savedAt: savedAt,
            status: .processing
        )
        var updated = saved
        updated.insert(post, at: 0)
        try persistSaved(updated)
        saved = updated
        events?(.linkSaved)
        startExtraction(post.id)
        return post.id
    }

    func retryExtraction(_ id: UUID) {
        guard let post = post(id: id) else { return }
        // A video post has no link to look up again: search what was read from it, or ask.
        if post.platform == .video {
            guard let evidence = post.caption, !evidence.isEmpty else {
                updateAndPersist(id) {
                    $0.status = .needsEvidence
                    $0.failureMessage = Self.shareVideoAgainMessage
                }
                return
            }
            submitEvidence(postID: id, text: evidence)
            return
        }
        guard updateAndPersist(id, mutation: {
            $0.status = .processing
            $0.failureMessage = nil
        }) else { return }
        startExtraction(id)
    }

    func removePost(_ id: UUID) {
        let updated = saved.filter { $0.id != id }
        do {
            try persistSaved(updated)
            saved = updated
        } catch {
            savedErrorMessage = "We couldn't remove this save. Try again."
        }
    }

    @discardableResult
    func confirm(postID: UUID, candidateID: String) -> Bool {
        guard let candidate = post(id: postID)?.candidates.first(where: { $0.id == candidateID }) else { return false }
        let confirmed = updateAndPersist(postID) { post in
            post.place = candidate.place
            post.placeProviderID = candidate.id
            post.estimatedCost = candidate.estimatedCost
            post.status = .ready
            post.candidates = []
        }
        if confirmed {
            events?(.placeSaved)
            placesAdded += 1
        }
        return confirmed
    }

    func submitEvidence(postID: UUID, text: String) {
        guard updateAndPersist(postID, mutation: {
            $0.caption = text
            $0.status = .processing
            $0.failureMessage = nil
        }) else { return }
        findingStartedAt[postID] = .now
        Task { await resolveEvidence(postID: postID, text: text) }
    }

    @discardableResult
    func saveVideo(fileURL: URL) async throws -> UUID {
        let id = UUID()
        let sourceURL = URL(string: "plandit-video://\(id.uuidString)")!
        let post = SavedPost(
            id: id,
            url: sourceURL,
            canonicalURL: sourceURL,
            platform: .video,
            savedAt: .now,
            status: .processing
        )
        var updated = saved
        updated.insert(post, at: 0)
        try persistSaved(updated)
        saved = updated

        readingVideos.insert(id)
        defer { readingVideos.remove(id) }
        do {
            try await applyVideoEvidence(postID: id, fileURL: fileURL)
        } catch {
            removePost(id)
            throw error
        }
        // Only a post that stays counts as a save.
        events?(.linkSaved)
        return id
    }

    func processVideo(postID: UUID, fileURL: URL) async throws {
        guard post(id: postID) != nil else { throw SavedPlacePersistenceError() }
        guard updateAndPersist(postID, mutation: {
            $0.status = .processing
            $0.failureMessage = nil
        }) else {
            throw SavedPlacePersistenceError()
        }
        readingVideos.insert(postID)
        defer { readingVideos.remove(postID) }
        do {
            try await applyVideoEvidence(postID: postID, fileURL: fileURL)
        } catch {
            updateAndPersist(postID) {
                $0.status = .needsEvidence
                $0.failureMessage = Self.videoFailureMessage(error)
            }
            throw error
        }
    }

    /// Deletes videos that waited more than 24 hours without being read (SHR-3).
    func removeExpiredTemporaryMedia(now: Date = Date()) {
        mediaStore.removeExpiredFiles(now: now)
    }

    private func startExtraction(_ id: UUID) {
        guard inFlight.insert(id).inserted else { return }
        findingStartedAt[id] = .now
        Task { await extract(id) }
    }

    /// Looks the post up. A network error or timeout gets one more try after a short wait, before
    /// the post says it couldn't find a place (PRC-3).
    private func extract(_ id: UUID) async {
        defer { inFlight.remove(id) }
        guard let post = post(id: id) else { return }
        do {
            let result: ExtractionResult
            do {
                result = try await extractor.extract(from: post.url, sharedText: post.caption)
            } catch let error where !(error is DevelopmentSocialEvidenceError) && !(error is CancellationError) {
                try await Task.sleep(for: extractionRetryDelay)
                guard let current = self.post(id: id), current.status == .processing else { return }
                result = try await extractor.extract(from: current.url, sharedText: current.caption)
            }
            let updated = applyExtractionResult(result, to: id)
            if updated, result.autoConfirmedCandidateID != nil {
                events?(.placeSaved)
                placesAdded += 1
            }
        } catch let error as DevelopmentSocialEvidenceError {
            updateAndPersist(id) {
                $0.status = .needsEvidence
                $0.failureMessage = error.localizedDescription
            }
        } catch {
            updateAndPersist(id) {
                $0.status = .failed
                $0.failureMessage = Self.lookupFailedMessage
            }
        }
    }

    @discardableResult
    private func applyExtractionResult(_ result: ExtractionResult, to id: UUID) -> Bool {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return false }
        var updated = saved
        updated[index].apply(result)
        if let canonicalURL = result.canonicalURL {
            if updated.contains(where: {
                $0.id != id && $0.canonicalURL == canonicalURL && $0.isMappable
            }) {
                updated.removeAll { $0.id == id }
                do {
                    try persistSaved(updated)
                    saved = updated
                    return false
                } catch {
                    savedErrorMessage = "We couldn't save that change. Try again."
                    return false
                }
            }
            updated.removeAll {
                $0.id != id && $0.canonicalURL == canonicalURL
            }
        }
        do {
            try persistSaved(updated)
            saved = updated
            return true
        } catch {
            savedErrorMessage = "We couldn't save that change. Try again."
            saved[index].status = .failed
            saved[index].failureMessage = "This change wasn't saved. Try again."
            return false
        }
    }

    private func applyVideoEvidence(postID: UUID, fileURL: URL) async throws {
        let evidence = try await videoExtractor.extract(from: fileURL)
        guard updateAndPersist(postID, mutation: {
            $0.caption = evidence.text
            $0.status = .processing
            $0.failureMessage = evidence.transcriptionNotice
        }) else {
            throw SavedPlacePersistenceError()
        }
        await resolveEvidence(
            postID: postID,
            text: evidence.text,
            noCandidatesMessage: evidence.transcriptionNotice
                ?? "We couldn't confidently match this video. Review the extracted details and try again."
        )
    }

    private func resolveEvidence(
        postID: UUID,
        text: String,
        noCandidatesMessage: String? = nil
    ) async {
        guard inFlight.insert(postID).inserted, let post = post(id: postID) else { return }
        defer { inFlight.remove(postID) }
        do {
            let result = try await extractor.resolve(evidence: text, platform: post.platform)
            let updated = updateAndPersist(postID) {
                $0.apply(result)
                if result.candidates.isEmpty {
                    $0.failureMessage = noCandidatesMessage
                }
            }
            if updated, result.autoConfirmedCandidateID != nil {
                events?(.placeSaved)
                placesAdded += 1
            }
        } catch {
            updateAndPersist(postID) {
                $0.status = .failed
                $0.failureMessage = "We couldn't match those details. Try another name or neighborhood."
            }
        }
    }

    @discardableResult
    private func updateAndPersist(
        _ id: UUID,
        mutation: (inout SavedPost) -> Void
    ) -> Bool {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return false }
        var updated = saved
        mutation(&updated[index])
        do {
            try persistSaved(updated)
            saved = updated
            return true
        } catch {
            savedErrorMessage = "We couldn't save that change. Try again."
            saved[index].status = .failed
            saved[index].failureMessage = "This change wasn't saved. Try again."
            return false
        }
    }

    private func persistSaved(_ updatedSaved: [SavedPost]) throws {
        pendingSave?.cancel()
        pendingSave = nil
        guard let storage, !isClosed else { return }
        let snapshot = StoreSnapshot(
            saved: updatedSaved,
            today: today,
            profile: profile,
            pastPlans: pastPlans,
            visited: visited,
            sharedLink: sharedLink,
            planRequest: planRequest
        )
        try storage.save(snapshot)
        onChange?(snapshot)
    }

    // MARK: - Today's plan

    /// Fits a saved place into the part of today still ahead, where it's open, adds the least travel
    /// and moves the fewest stops (`DayPlan.inserting`). Returns the new stop's id.
    @discardableResult
    func addToToday(_ postID: UUID) -> UUID? {
        guard let post = post(id: postID), !isInToday(post), let candidate = PlanCandidate(post: post) else { return nil }
        let wasEmpty = today.stops.isEmpty
        remember("Added \(candidate.place.name)")
        today = today.inserting(candidate, travel: travelPreference, now: AppClock.now).plan
        if wasEmpty { today.title = Self.title(for: today.stops) }
        persist()
        events?(.planBuilt)
        Task { await loadRoutes() }
        return candidate.id
    }

    /// Stops whose time is over but aren't marked done (`DayPlan.overdueStops`).
    func overdueStops(now: Date = AppClock.now) -> [PlanStop] {
        today.overdueStops(now: now)
    }

    func markOverdueDone(now: Date = AppClock.now) {
        let count = today.overdueStops(now: now).count
        remember(count == 1 ? "Marked 1 stop done" : "Marked \(count) stops done")
        today.markOverdueDone(now: now)
        persist()
    }

    func startRestFromNow(now: Date = AppClock.now) {
        remember("Moved the rest of the day later")
        today.startRestFromNow(now: now)
        persist()
    }

    /// The stops still ahead, in a new order and minus any taken out, before saving it.
    func previewReorder(_ ids: [UUID]) -> DayPlan {
        today.edited(keeping: ids, travel: travelPreference)
    }

    /// Saves the Edit plan sheet: the stops still ahead in this order; any left out are removed.
    func reorder(_ ids: [UUID]) {
        let plan = today.edited(keeping: ids, travel: travelPreference)
        guard plan.stops.map(\.id) != today.stops.map(\.id) else { return }
        let kept = Set(plan.stops.map(\.id))
        let removed = today.stops.filter { !kept.contains($0.id) }
        switch removed.count {
        case 0: remember("Changed the order")
        case 1: remember("Removed \(removed[0].place.name)")
        default: remember("Removed \(removed.count) stops")
        }
        today = plan
        persist()
        Task { await loadRoutes() }
    }

    func removeStop(_ id: UUID) {
        guard let stop = stop(id: id) else { return }
        remember("Removed \(stop.place.name)")
        today.stops.removeAll { $0.id == id }
        rebuildLegs()
        // A new trip between the stops either side may be longer; push later stops only if they'd overlap.
        today.shiftStops(from: today.firstMovableIndex, by: 0, calendar: .current)
        persist()
    }

    /// "I'm here": this stop is happening now, everything before it is done, everything after is still planned.
    func arrive(at stopID: UUID) {
        guard let index = stopIndex(id: stopID) else { return }
        remember(today.stops[index].status == .done ? "\(today.stops[index].place.name) isn't done" : "You're at \(today.stops[index].place.name)")
        setStatuses(doneThrough: index - 1, now: index)
    }

    /// "Done here": this stop and everything before it are done; the next stop becomes "now".
    func complete(_ stopID: UUID) {
        guard let index = stopIndex(id: stopID) else { return }
        remember("\(today.stops[index].place.name) is done")
        setStatuses(doneThrough: index, now: index + 1 < today.stops.count ? index + 1 : nil)
    }

    /// "Not here yet": back to planned. Stops before it stay done; nothing is underway.
    func leave(_ stopID: UUID) {
        guard let index = stopIndex(id: stopID) else { return }
        let name = today.stops[index].place.name
        remember(today.stops[index].status == .done ? "\(name) is back to planned" : "Not at \(name) yet")
        setStatuses(doneThrough: index - 1, now: nil)
    }

    // MARK: - Sharing the plan as a link

    /// Today's link, if today's plan is the one shared.
    var todayLink: SharedLink? {
        guard let sharedLink, sharedLink.planID == today.id else { return nil }
        return sharedLink
    }

    var canShareLinks: Bool { sharing != nil }

    /// Creates today's link (or updates its page with new options) and remembers it. With
    /// `suggestsSwaps`, the page offers friends up to two saved places per stop (`swapOptions`).
    /// With `request`, the plan was built from that "Ask friends what works" link, which then opens
    /// this plan (GI-7).
    @discardableResult
    func shareToday(showPrices: Bool, note: String, suggestsSwaps: Bool = true, request: String? = nil) async throws -> SharedLink {
        guard let sharing else { throw APIError.network }
        // Nothing older may land after this (`holdPageUpdates`).
        holdPageUpdates()
        let sent: (slug: String, url: URL, payload: SharedPlanPayload)
        do {
            sent = try await inTurn {
                var payload = sharedPayload(showPrices: showPrices, note: note, suggestsSwaps: suggestsSwaps)
                payload.request = request
                let created = try await sharing.publish(payload)
                // Page updates never carry the request: compare them with the page itself.
                payload.request = nil
                return (created.slug, created.url, payload)
            }
        } catch {
            resumePageUpdates()
            throw error
        }
        linkOperations -= 1
        let payload = sent.payload
        var link = SharedLink(slug: sent.slug, url: sent.url, planID: payload.planId, showPrices: showPrices,
                              note: note, suggestsSwaps: suggestsSwaps)
        if let previous = sharedLink, previous.slug == link.slug { link.keptSwaps = previous.keptSwaps }
        lastPublished = payload
        sharedLink = link
        persist()
        return link
    }

    /// Takes the page down; the link stops working and friends' answers go with it.
    func stopSharing() async throws {
        guard let link = sharedLink else { return }
        // Nothing may land after the page is taken down (`holdPageUpdates`).
        holdPageUpdates()
        do {
            if let sharing { try await inTurn { try await sharing.unpublish(slug: link.slug) } }
        } catch {
            resumePageUpdates()
            throw error
        }
        linkOperations -= 1
        sharedLink = nil
        lastPublished = nil
        forgetAnswers()
        persist()
        // The page is down: nothing may bring it back.
        pendingShareUpdate?.cancel()
        pendingShareUpdate = nil
    }

    /// The saved places friends could pick instead of each stop still ahead: what the share preview
    /// lists and the page offers with "Let friends suggest swaps" on.
    var swapOptions: [UUID: [SavedPost]] {
        SwapOptions.all(for: today, saves: saved)
    }

    private func sharedPayload(showPrices: Bool, note: String, suggestsSwaps: Bool) -> SharedPlanPayload {
        today.sharedPayload(showPrices: showPrices, note: note, alternates: suggestsSwaps ? swapOptions : [:])
    }

    /// After a change to a shared plan, the page catches up a moment later. Failures are quiet:
    /// the next change tries again. An update still waiting is replaced, so a change undone before
    /// it goes out sends nothing. One already being sent is never stopped (the server may have
    /// applied it), so while one is out the plan as it is now goes out after it, even if that's
    /// what was last published: the latest always lands last.
    private func scheduleShareUpdate() {
        guard linkOperations == 0, let link = todayLink, let sharing else { return }
        let payload = sharedPayload(showPrices: link.showPrices, note: link.note, suggestsSwaps: link.suggestsSwaps)
        pendingShareUpdate?.cancel()
        pendingShareUpdate = nil
        guard payload != lastPublished || isSendingToPage else { return }
        pendingShareUpdate = Task { [weak self] in
            try? await Task.sleep(for: Self.shareUpdateDelay)
            guard !Task.isCancelled, let self else { return }
            await self.inTurn {
                // Replaced while it waited for the one before.
                guard !Task.isCancelled else { return }
                // Being sent now: a later change no longer cancels it.
                self.pendingShareUpdate = nil
                // Only while this plan is still shared and no Share plan or Stop sharing is out:
                // publishing a page that was taken down would bring it back.
                guard self.linkOperations == 0, let link = self.todayLink, link.planID == payload.planId else {
                    return
                }
                if (try? await sharing.publish(payload)) != nil { self.lastPublished = payload }
            }
        }
    }

    /// Before Share plan or Stop sharing talks to the server: the update waiting is dropped (what
    /// they send replaces it), and changes made meanwhile wait until the last of them is done. Their
    /// request then waits its turn behind an update being sent (`inTurn`), so it lands last.
    private func holdPageUpdates() {
        pendingShareUpdate?.cancel()
        pendingShareUpdate = nil
        linkOperations += 1
    }

    /// When Share plan or Stop sharing failed: the link stays as it was, and changes made meanwhile
    /// go out with it, unless another of them is still out (the last one to end decides).
    private func resumePageUpdates() {
        linkOperations -= 1
        scheduleShareUpdate()
    }

    /// Requests to the page go out one at a time, in the order they ask, so the last one sent is
    /// the last one the server applies.
    private func inTurn<T>(_ request: () async throws -> T) async rethrows -> T {
        if isSendingToPage {
            await withCheckedContinuation { pageTurnWaiters.append($0) }
        } else {
            isSendingToPage = true
        }
        defer {
            // Hand the turn to the next in line, if any.
            if pageTurnWaiters.isEmpty { isSendingToPage = false } else { pageTurnWaiters.removeFirst().resume() }
        }
        return try await request()
    }

    static var shareUpdateDelay: Duration = .seconds(2)

    // MARK: - Friends' answers (group plans, mode 1)

    /// Today's link's answers; none without a link.
    var shareAnswers: [ShareAnswer] {
        guard let link = todayLink, link.slug == answersSlug else { return [] }
        return fetchedAnswers
    }

    /// "3 in · 1 can't make it" under the share button; nil with no answers.
    var answerSummary: ShareAnswerSummary? { ShareAnswers.summary(shareAnswers) }

    /// Friends' "I'd swap this" per stop still ahead, minus picks the organizer kept the stop over.
    var swapMarks: [UUID: [SwapPick]] {
        ShareAnswers.swapMarks(shareAnswers, plan: today, kept: Set(todayLink?.keptSwaps ?? []))
    }

    /// How often Today appearing or the app opening may ask for answers.
    static var answersRefreshInterval: TimeInterval = 10

    /// Fetches the answers on today's link, at most every `answersRefreshInterval` unless forced.
    /// Failures are quiet: what was shown stays, and the next appearance tries again.
    func refreshShareAnswers(now: Date = Date(), force: Bool = false) async {
        guard let link = todayLink, let answerClient else { return }
        if !force, let asked = answersAsked, asked.slug == link.slug,
           now.timeIntervalSince(asked.at) < Self.answersRefreshInterval { return }
        let previous = answersAsked
        answersAsked = (link.slug, now)
        let changes = answersChanges
        guard let answers = try? await answerClient.answers(slug: link.slug) else {
            if answersAsked?.slug == link.slug, answersAsked?.at == now { answersAsked = previous }
            return
        }
        // Shared again, or stopped, or an answer removed while the request was out: what it read
        // may be from before that.
        guard todayLink?.slug == link.slug, answersChanges == changes else { return }
        answersSlug = link.slug
        if answers != fetchedAnswers { fetchedAnswers = answers }
    }

    /// Removes a friend's answer from the link: it's gone from the page and Today (GV-7).
    func removeShareAnswer(_ id: UUID) async throws {
        guard let link = todayLink, let answerClient else { return }
        try await answerClient.remove(slug: link.slug, answerID: id)
        answersChanges += 1
        fetchedAnswers.removeAll { $0.id == id }
    }

    private func forgetAnswers() {
        answersChanges += 1
        fetchedAnswers = []
        answersSlug = nil
        answersAsked = nil
    }

    enum SwapAvailability: Equatable {
        case available
        case alreadyInPlan
        /// The organizer removed it from Saved, or it has no place any more.
        case notSaved
    }

    /// Whether "Swap it" can put a friend's pick (a saved post's id) into today's plan.
    func swapAvailability(of postID: UUID) -> SwapAvailability {
        guard let post = post(id: postID), post.isMappable, let place = post.place else { return .notSaved }
        let inPlan = isInToday(post) || today.stops.contains {
            $0.place.name.lowercased() == place.name.lowercased() && $0.place.address.lowercased() == place.address.lowercased()
        }
        return inPlan ? .alreadyInPlan : .available
    }

    /// "Swap it": the stop becomes the friend's pick, in the same place in the day, and the times
    /// from there on are planned again (GV-6). Undo puts the stop back; the page updates as with
    /// any other change (`scheduleShareUpdate`), and the undo bar says so when it will. False when
    /// the stop isn't still ahead or the pick can't go in.
    @discardableResult
    func swap(stopID: UUID, toPost postID: UUID, now: Date = AppClock.now) -> Bool {
        guard let old = stop(id: stopID), swapAvailability(of: postID) == .available,
              let post = post(id: postID), let candidate = PlanCandidate(post: post),
              let plan = today.swapping(stopID, for: candidate, travel: travelPreference, now: now) else { return false }
        let updatesLink = todayLink != nil && sharing != nil
        remember("Swapped \(old.place.name) for \(candidate.place.name)" + (updatesLink ? ". Your link updates too." : ""))
        today = plan
        persist()
        Task { await loadRoutes() }
        return true
    }

    /// "Keep it": the stop stays, and these picks stop showing until a friend picks another place.
    func keepStop(_ stopID: UUID) {
        guard var link = todayLink, let picks = swapMarks[stopID] else { return }
        // Picks about stops no longer in the plan can't show again; no need to keep them.
        var kept = link.keptSwaps.filter { key in today.stops.contains { key.hasPrefix($0.id.uuidString) } }
        for pick in picks {
            // One kept pick per friend and stop: the latest.
            let prefix = ShareAnswers.keepPrefix(stopID: stopID, answerID: pick.answerID)
            kept.removeAll { $0.hasPrefix(prefix) }
            kept.append(ShareAnswers.keepKey(stopID: stopID, pick: pick))
        }
        link.keptSwaps = kept
        sharedLink = link
        persist()
    }

    // MARK: - Ask friends what works (group plans, mode 2)

    /// Making a link needs the server: the answers are read from it and the plan goes on a link.
    var canAskFriends: Bool { requestClient != nil && sharing != nil }

    /// The link still in play: its day hasn't gone by. One for an earlier day is left to the
    /// server's clean-up (GS-5), and the planner offers a new one.
    func activeRequest(now: Date = AppClock.now) -> PlanRequestLink? {
        guard let planRequest, !planRequest.isOver(now: now) else { return nil }
        return planRequest
    }

    /// The link's request with friends' answers, as last fetched; nil before the first fetch.
    var requestDetails: PlanRequest? {
        guard let fetchedRequest, fetchedRequest.slug == planRequest?.slug else { return nil }
        return fetchedRequest
    }

    /// How often the answers screen appearing or the app opening may ask again.
    static var requestRefreshInterval: TimeInterval = 10

    /// Makes the link for `draft` (GI-1) and keeps it. `answersBy` is the draft's deadline.
    func createPlanRequest(_ draft: PlanRequestDraft, answersBy: Date) async throws {
        guard let requestClient else { throw APIError.network }
        let created = try await requestClient.create(draft)
        requestChanges += 1
        planRequest = PlanRequestLink(request: created, draft: draft, answersBy: answersBy)
        fetchedRequest = created
        requestFetchFailed = false
        requestAsked = (created.slug, Date())
        persist()
    }

    /// Reads the link's answers, at most every `requestRefreshInterval` unless forced. A failure
    /// keeps what was shown, and the next appearance tries again; with nothing read yet it sets
    /// `requestFetchFailed`. A link the server no longer has (deleted on another phone, or cleaned
    /// up) is forgotten.
    func refreshPlanRequest(now: Date = Date(), force: Bool = false) async {
        guard let link = planRequest, let requestClient else { return }
        if !force, let asked = requestAsked, asked.slug == link.slug,
           now.timeIntervalSince(asked.at) < Self.requestRefreshInterval { return }
        let previous = requestAsked
        requestAsked = (link.slug, now)
        let changes = requestChanges
        let fetched: PlanRequest?
        do {
            fetched = try await requestClient.fetch(slug: link.slug)
        } catch {
            if requestAsked?.slug == link.slug, requestAsked?.at == now { requestAsked = previous }
            if planRequest?.slug == link.slug, requestDetails == nil { requestFetchFailed = true }
            return
        }
        // A new link, a removed answer, closing or building while the request was out: what it
        // read may be from before that.
        guard planRequest?.slug == link.slug, requestChanges == changes else { return }
        requestFetchFailed = false
        guard let fetched else {
            fetchedRequest = nil
            planRequest = nil
            persist()
            return
        }
        if fetched != fetchedRequest { fetchedRequest = fetched }
    }

    /// Takes a friend's answer off the link: it no longer counts (GS-4).
    func removeRequestAnswer(_ id: UUID) async throws {
        guard let link = planRequest, let requestClient else { return }
        try await requestClient.removeAnswer(slug: link.slug, answerID: id)
        requestChanges += 1
        if fetchedRequest?.slug == link.slug { fetchedRequest?.answers.removeAll { $0.id == id } }
    }

    /// The link stops taking answers before its deadline (GI-3). The plan can still be built.
    func closePlanRequest() async throws {
        guard let link = planRequest, let requestClient else { return }
        try await requestClient.close(slug: link.slug)
        requestChanges += 1
        if fetchedRequest?.slug == link.slug, fetchedRequest?.status == .open { fetchedRequest?.status = .closed }
    }

    /// "Ask about another day": forgets this link so a new one can be made. One that never got a
    /// plan is deleted with its answers; one that opens a plan is kept on the server, so friends'
    /// link still works, until it's cleaned up 30 days after its day (GS-5).
    func discardPlanRequest() async throws {
        guard let link = planRequest else { return }
        let opensAPlan = link.builtPlanID != nil || requestDetails?.status == .built
        if !opensAPlan, let requestClient { try await requestClient.delete(slug: link.slug) }
        requestChanges += 1
        planRequest = nil
        fetchedRequest = nil
        requestAsked = nil
        requestFetchFailed = false
        persist()
    }

    /// The organizer's own inputs until they change them: their default budget and the whole
    /// range (GI-5).
    func organizerInputs(for link: PlanRequestLink) -> GroupInputs.Person {
        GroupInputs.Person(member: .organizer, budget: profile.defaultBudget,
                           from: link.start ?? ClockTime(12), until: link.end ?? ClockTime(20), stars: [])
    }

    /// Everyone's inputs together (`GroupInputs.combine`), over the link's places still saved. Nil
    /// until the answers have been read: a plan from the organizer's inputs alone would leave
    /// friends out.
    func groupInputs(organizer: GroupInputs.Person, leftOut: Set<GroupMember>) -> GroupInputs.Result? {
        guard let link = planRequest, let details = requestDetails else { return nil }
        let places = link.placeIDs.filter { post(id: $0)?.isMappable == true }
        return GroupInputs.combine(answers: details.answers, organizer: organizer, places: places, leftOut: leftOut)
    }

    /// What "Build our plan" would put in Today, without changing anything. Nil when the link
    /// isn't for today: the app only keeps today's plan.
    func previewGroupPlan(_ plan: GroupInputs.Plan, now: Date = AppClock.now) -> DayPlanner.Outcome? {
        groupPlanRequest(plan, now: now).map { DayPlanner(travel: travelPreference).plan($0) }
    }

    /// "Build our plan": the answers' plan replaces today's and the link remembers it. Then
    /// `shareGroupPlan` puts it on the link. Until that works, Undo puts the old plan back (and
    /// Build is offered again); once friends' link opens it, there's no Undo: the organizer changes
    /// it in Today, as with any shared plan. Nil when the link isn't for today.
    @discardableResult
    func buildGroupPlan(_ plan: GroupInputs.Plan, now: Date = AppClock.now) -> DayPlanner.Outcome? {
        guard var link = planRequest, let request = groupPlanRequest(plan, now: now) else { return nil }
        let outcome = DayPlanner(travel: travelPreference).plan(request)
        guard !outcome.stops.isEmpty else { return outcome }
        remember(Self.groupBuildUndoMessage, isGroupBuild: true)
        today.stops = outcome.stops
        today.legs = outcome.legs
        legPaths = [:]
        today.budget = plan.budget
        today.title = Self.title(for: today.stops)
        link.builtPlanID = today.id
        link.builtStopIDs = today.stops.map(\.id)
        planRequest = link
        requestChanges += 1
        persist()
        events?(.planBuilt)
        Task { await loadRoutes() }
        return outcome
    }

    /// Puts the plan built from the answers on today's link, with the request's slug, so friends'
    /// /g/ link now opens it (GI-7). It goes out like Share plan, one at a time with page updates.
    /// An existing link keeps its settings; a new one shows prices, and no swaps, since the
    /// organizer hasn't seen swap options for this plan (GV-9).
    func shareGroupPlan() async throws {
        guard groupPlanAwaitsLink, let link = planRequest else { throw APIError.invalidResponse }
        let current = todayLink
        try await shareToday(showPrices: current?.showPrices ?? true, note: current?.note ?? "",
                             suggestsSwaps: current?.suggestsSwaps ?? false, request: link.slug)
        // Friends' link opens this plan now: undoing the build would put the old one there.
        if undo?.isGroupBuild == true { undo = nil }
        requestChanges += 1
        if fetchedRequest?.slug == link.slug { fetchedRequest?.status = .built }
        await refreshPlanRequest(force: true)
    }

    /// The plan "Build our plan" put in Today is still there, with the same stops, and isn't on
    /// friends' link yet: "Try again" puts it there. False once it's undone or another plan
    /// replaced it, so the link never gets a plan that wasn't built from the answers.
    var groupPlanAwaitsLink: Bool {
        guard let link = planRequest, let builtID = link.builtPlanID, builtID == today.id,
              let stopIDs = link.builtStopIDs, let details = requestDetails, details.status != .built else { return false }
        return Set(stopIDs) == Set(today.stops.map(\.id))
    }

    static let groupBuildUndoMessage = "Built our plan. It isn't on the link yet."

    /// The planner's inputs for the answers' plan: from the start of everyone's time (or the next
    /// quarter hour, if that's later) to its end, on the lowest budget, most-starred places first.
    private func groupPlanRequest(_ plan: GroupInputs.Plan, now: Date) -> DayPlanner.Request? {
        guard let link = planRequest, link.isToday(now: now), let day = link.dayDate,
              let windowStart = plan.start.date(on: day, calendar: link.calendar),
              let windowEnd = plan.end.date(on: day, calendar: link.calendar) else { return nil }
        let start = max(windowStart, PlanDefaults.nextQuarterHour(after: now))
        let priorities = Dictionary(plan.candidates.map { ($0.placeID, $0.stars) }, uniquingKeysWith: max)
        var request = basePlanRequest(postIDs: plan.candidates.map(\.placeID), start: start, budget: plan.budget,
                                      mode: .replace, priorities: priorities)
        request.dayEnd = windowEnd
        return request
    }

    // MARK: - Undo

    struct PlanUndo: Identifiable {
        let id = UUID()
        let message: String
        let plan: DayPlan
        /// "Build our plan", before the plan went on friends' link.
        var isGroupBuild = false
    }

    /// Call before changing `today`.
    private func remember(_ message: String, isGroupBuild: Bool = false) {
        undo = PlanUndo(message: message, plan: today, isGroupBuild: isGroupBuild)
    }

    /// Puts today's plan back the way it was before the last change.
    func undoLastChange() {
        guard let undo else { return }
        today = undo.plan
        self.undo = nil
        if undo.isGroupBuild, var link = planRequest {
            // The built plan is gone: no "Try again" for it, and Build is offered again.
            link.builtPlanID = nil
            link.builtStopIDs = nil
            planRequest = link
        }
        persist()
        Task { await loadRoutes() }
    }

    /// For a change that has no undo of its own: the last one's snapshot predates it, so undoing
    /// would quietly take this change back too. Clearing it also hides the undo bar.
    private func forgetUndo() {
        undo = nil
    }

    func dismissUndo(_ id: UUID) {
        if undo?.id == id { undo = nil }
    }

    private func setStatuses(doneThrough: Int, now: Int?) {
        for index in today.stops.indices {
            today.stops[index].status = index <= doneThrough ? .done : (index == now ? .now : .upcoming)
        }
        persist()
    }

    /// Keeps existing legs between consecutive stops and estimates any new pairs.
    private func rebuildLegs() {
        today.relinkLegs(travel: travelPreference)
    }

    // MARK: - Planning (the + button)

    enum PlanMode: String, CaseIterable, Identifiable {
        /// Keep what's done or underway; re-order the rest of the day together with the new picks.
        case add
        /// Throw out today's plan and plan only the picks.
        case replace

        var id: String { rawValue }
    }

    var travelPreference: TravelPreference { TravelPreference(setting: profile.travelModes) }

    /// Saved posts with a place, ready to plan.
    var plannablePosts: [SavedPost] { saved.filter(\.isMappable) }

    /// Stops already done or underway. Re-planning never moves these.
    var lockedStops: [PlanStop] {
        guard let last = today.stops.lastIndex(where: { $0.status != .upcoming }) else { return [] }
        return Array(today.stops[...last])
    }

    /// Money already spent on locked stops and the travel between them.
    var lockedCost: Double {
        let locked = lockedStops
        let ids = Set(locked.map(\.id))
        return locked.reduce(0) { $0 + $1.estimatedCost }
            + today.legs.filter { ids.contains($0.fromStopID) && ids.contains($0.toStopID) }.reduce(0) { $0 + $1.cost }
    }

    /// What `buildPlan` would do, without changing anything. Cheap enough to run on every change.
    /// `end` is when the user is free until; at or before the start means the early hours of the next day.
    func previewPlan(postIDs: [UUID], start: Date, budget: Double, mode: PlanMode, end: Date? = nil) -> DayPlanner.Outcome {
        DayPlanner(travel: travelPreference).plan(planRequest(postIDs: postIDs, start: start, budget: budget, mode: mode, end: end))
    }

    /// Plans the picked saved posts into today and switches the map to the new route.
    @discardableResult
    func buildPlan(postIDs: [UUID], start: Date, budget: Double, mode: PlanMode, end: Date? = nil) -> DayPlanner.Outcome {
        let outcome = previewPlan(postIDs: postIDs, start: start, budget: budget, mode: mode, end: end)
        if !outcome.stops.isEmpty { remember(mode == .replace ? "Made a new plan" : "Added to today's plan") }
        switch mode {
        case .replace:
            today.stops = outcome.stops
            today.legs = outcome.legs
            legPaths = [:]
        case .add:
            let locked = lockedStops
            let lockedIDs = Set(locked.map(\.id))
            let chosen = today.legs.filter(\.isChosen)
            today.stops = locked + outcome.stops
            today.legs = today.legs.filter { lockedIDs.contains($0.fromStopID) && lockedIDs.contains($0.toStopID) } + outcome.legs
            // Trips the user picked a way for stay that way when the same two stops are still next to each other.
            for leg in today.legs {
                if let pick = chosen.first(where: { $0.fromStopID == leg.fromStopID && $0.toStopID == leg.toStopID }), pick.mode != leg.mode {
                    var kept = pick
                    kept.id = leg.id
                    today.setLeg(kept)
                }
            }
        }
        today.budget = budget
        if mode == .replace || lockedStops.isEmpty {
            today.title = Self.title(for: today.stops)
        }
        persist()
        if !outcome.stops.isEmpty { events?(.planBuilt) }
        Task { await loadRoutes() }
        return outcome
    }

    private func planRequest(postIDs: [UUID], start: Date, budget: Double, mode: PlanMode, end: Date?) -> DayPlanner.Request {
        let request = basePlanRequest(postIDs: postIDs, start: start, budget: budget, mode: mode)
        guard let end else { return request }
        var bounded = request
        let dayStart = request.anchor?.end ?? request.start
        // "Until 1 AM" after a 10 PM start means tomorrow; "until 2 PM" after 3 PM just means nothing fits.
        let rollsOver = end <= dayStart && Calendar.current.component(.hour, from: end) < 6
        bounded.dayEnd = rollsOver ? Calendar.current.date(byAdding: .day, value: 1, to: end) : end
        return bounded
    }

    /// `priorities` (saved post id → priority) are for "Build our plan": how many people starred each place.
    private func basePlanRequest(postIDs: [UUID], start: Date, budget: Double, mode: PlanMode, priorities: [UUID: Int] = [:]) -> DayPlanner.Request {
        var seen = Set<UUID>()
        let picked = postIDs.filter { seen.insert($0).inserted }.compactMap { post(id: $0) }.compactMap(PlanCandidate.init(post:))
            .map { candidate -> PlanCandidate in
                var candidate = candidate
                candidate.priority = candidate.sourcePostID.flatMap { priorities[$0] } ?? 0
                return candidate
            }
        switch mode {
        case .replace:
            return DayPlanner.Request(candidates: picked, start: start, budget: budget, alreadySpent: today.extras.total)
        case .add:
            let locked = lockedStops
            let lockedIDs = Set(locked.map(\.id))
            let upcoming = today.stops.filter { !lockedIDs.contains($0.id) }
            let alreadyIn = Set(today.stops.compactMap(\.sourcePostID))
            let fresh = picked.filter { candidate in candidate.sourcePostID.map { !alreadyIn.contains($0) } ?? true }
            let lockedLegCost = today.legs.filter { lockedIDs.contains($0.fromStopID) && lockedIDs.contains($0.toStopID) }
                .reduce(0) { $0 + $1.cost }
            return DayPlanner.Request(
                candidates: upcoming.map(PlanCandidate.init(stop:)) + fresh,
                start: locked.last?.end ?? start,
                budget: budget,
                anchor: locked.last,
                alreadySpent: locked.reduce(0) { $0 + $1.estimatedCost } + lockedLegCost + today.extras.total
            )
        }
    }

    /// "Morningside Heights to West Village", or "A day in Chelsea" when it never leaves one neighborhood.
    static func title(for stops: [PlanStop]) -> String {
        guard let first = stops.first?.place.neighborhood, let last = stops.last?.place.neighborhood,
              !first.isEmpty, !last.isEmpty else { return "Today" }
        return first == last ? "A day in \(first)" : "\(first) to \(last)"
    }

    // MARK: - Suggested plans (the empty Today)

    /// Up to three plans built from saved places, for an empty Today; none once it has a plan.
    /// Worked out on the phone and never stored or synced.
    private(set) var suggestions: [PlanSuggestion] = []
    /// Set when a tapped card had gone stale and the cards were refreshed (SP-11).
    private(set) var suggestionNotice: String?
    /// Where suggestions start: the planner's default start, so "Change it" lands on the same time.
    @ObservationIgnored var suggestionStart: () -> Date = { PlanDefaults.start() }
    /// What the current suggestions were worked out from. Between changes to it, the cards stay put.
    @ObservationIgnored private var suggestionKey: SuggestionKey?
    /// Saved posts checked off on some date; only today's count (see `postsDoneToday`).
    @ObservationIgnored private var doneToday: DoneToday?

    static let suggestionsChangedMessage = "It's later now, so these plans changed."

    enum UseResult: Equatable {
        case applied
        /// The card no longer matches what the planner would build; the cards were refreshed instead.
        case stale
    }

    private struct SuggestionKey: Equatable {
        /// The 15-minute time slot of the start.
        var slot: Int
        var saves: Int
        var budget: Double
        var travel: TravelPreference
        var extras: Double
        var done: Set<UUID>
    }

    /// Saved posts checked off today, even if they've since left the plan. Not suggested again
    /// today (SP-9); a new day starts with none.
    var postsDoneToday: Set<UUID> {
        guard let doneToday, doneToday.day == DoneToday.key(for: today.date) else { return [] }
        return doneToday.postIDs
    }

    /// Keeps `postsDoneToday` in step with the plan: a stop marked done adds its post, a stop in
    /// the plan that isn't done (Undo, "Not here yet") takes it out, and a stop removed from the
    /// plan leaves it as it was. Written to this phone only, beside the snapshot.
    ///
    /// Only a plan for the real current day is recorded. Another phone's copy from another day
    /// (after sync, written before `replace(with:)` rolls it over) leaves today's set alone.
    private func noteDoneStops() {
        guard Calendar.current.isDate(today.date, inSameDayAs: .now) else { return }
        let day = DoneToday.key(for: today.date)
        var done = postsDoneToday
        for stop in today.stops {
            guard let postID = stop.sourcePostID else { continue }
            if stop.status == .done { done.insert(postID) } else { done.remove(postID) }
        }
        let next = DoneToday(day: day, postIDs: done)
        guard next != doneToday else { return }
        doneToday = next
        guard let storage, !isClosed else { return }
        try? storage.saveDoneToday(next)
    }

    /// Works the suggestions out again if anything they depend on changed: the saves, the default
    /// budget, the travel setting, Today, or the 15-minute slot the start time is in (SP-8).
    func refreshSuggestions() {
        guard today.stops.isEmpty else {
            suggestionKey = nil
            if !suggestions.isEmpty { suggestions = [] }
            if suggestionNotice != nil { suggestionNotice = nil }
            return
        }
        let start = suggestionStart()
        var saves = Hasher()
        for post in saved where post.isMappable { saves.combine(post) }
        let done = postsDoneToday
        let key = SuggestionKey(
            slot: Int((start.timeIntervalSinceReferenceDate / (15 * 60)).rounded(.down)),
            saves: saves.finalize(),
            budget: profile.defaultBudget,
            travel: travelPreference,
            extras: today.extras.total,
            done: done
        )
        guard key != suggestionKey else { return }
        // "It's later now…" explains the cards it came with; once the time slot moves on, it goes.
        if let previous = suggestionKey, previous.slot != key.slot, suggestionNotice != nil { suggestionNotice = nil }
        suggestionKey = key
        let next = PlanSuggester(planner: DayPlanner(travel: travelPreference)).suggestions(
            posts: saved,
            excluding: done,
            start: start,
            budget: profile.defaultBudget,
            end: start.addingTimeInterval(PlanDefaults.suggestionLength),
            alreadySpent: today.extras.total
        )
        if next != suggestions { suggestions = next }
    }

    /// "Use this plan": makes exactly the card's plan today's plan, with the same undo step as
    /// building one by hand (SP-10). If the planner would now build something else (a stop has
    /// closed, the time slot moved), nothing changes: the cards are refreshed instead (SP-11).
    @discardableResult
    func useSuggestion(_ suggestion: PlanSuggestion) -> UseResult {
        guard today.stops.isEmpty else { return .stale }
        let start = suggestionStart()
        let end = start.addingTimeInterval(PlanDefaults.suggestionLength)
        let budget = profile.defaultBudget
        let preview = previewPlan(postIDs: suggestion.postIDs, start: start, budget: budget, mode: .replace, end: end)
        guard preview.isSamePlan(as: suggestion.outcome) else {
            suggestionKey = nil
            refreshSuggestions()
            suggestionNotice = Self.suggestionsChangedMessage
            return .stale
        }
        suggestionNotice = nil
        buildPlan(postIDs: suggestion.postIDs, start: start, budget: budget, mode: .replace, end: end)
        events?(.suggestionUsed)
        return .applied
    }

    // MARK: - Profile

    func updateProfile(_ change: (inout UserProfile) -> Void) {
        change(&profile)
        if today.stops.isEmpty { today.budget = profile.defaultBudget }
        persist()
    }

    // MARK: - Persistence

    var snapshot: StoreSnapshot {
        StoreSnapshot(saved: saved, today: today, profile: profile, pastPlans: pastPlans, visited: visited, sharedLink: sharedLink,
                      planRequest: planRequest)
    }

    /// The current state in the exact JSON shape the file and the cloud copy use.
    var encodedSnapshot: Data? { try? SnapshotStore.encode(snapshot) }

    /// Coalesces bursts of changes into one write a moment later.
    private func persist() {
        scheduleShareUpdate()
        noteDoneStops()
        refreshSuggestions()
        guard let storage, !isClosed else { return }
        let snapshot = snapshot
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !isClosed else { return }
            do {
                try storage.save(snapshot)
                pendingSave = nil
                onChange?(snapshot)
            } catch {
                print("Plandit: could not save state: \(error)")
            }
        }
    }

    /// Drops a queued write without performing it (the account's file is about to be deleted).
    func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    /// Writes a pending change immediately (call when the app leaves the foreground). With nothing
    /// pending it does nothing, so the sync hook never sees a change that did not happen.
    func flush() {
        guard pendingSave != nil else { return }
        persistNow()
    }

    /// Writes the current state now, pending change or not, and tells the hook.
    func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        noteDoneStops()
        refreshSuggestions()
        guard let storage, !isClosed else { return }
        let snapshot = snapshot
        guard (try? storage.save(snapshot)) != nil else { return }
        onChange?(snapshot)
    }
}

extension PlanditStore {
    /// The extractor a launched app uses. Debug builds take `-fakeExtraction slow|fail|match|pick`,
    /// so UI tests drive the finding-the-place screens without the network.
    static func launchExtractor(_ arguments: [String] = CommandLine.arguments) -> any PlaceExtracting {
#if DEBUG
        if let index = arguments.firstIndex(of: "-fakeExtraction"), index + 1 < arguments.count,
           let mode = LaunchFakeExtractor.Mode(rawValue: arguments[index + 1]) {
            return LaunchFakeExtractor(mode: mode)
        }
#endif
        return FixturePlaceExtractor()
    }
}

#if DEBUG
/// UI-test stand-in for the backend and MapKit. `slow` takes 30 s, then offers three places;
/// `fail` always times out; `match` adds Levain Bakery on its own; `pick` offers three places.
struct LaunchFakeExtractor: PlaceExtracting {
    enum Mode: String, Sendable { case slow, fail, match, pick }
    let mode: Mode

    func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
        let creator = url.pathComponents.first { $0.hasPrefix("@") }
        switch mode {
        case .fail:
            throw URLError(.timedOut)
        case .slow:
            try await Task.sleep(for: .seconds(30))
            return ExtractionResult(creatorHandle: creator, candidates: Self.three)
        case .pick:
            return ExtractionResult(creatorHandle: creator, candidates: Self.three)
        case .match:
            let levain = Self.three[0]
            return ExtractionResult(creatorHandle: creator, candidates: [levain], autoConfirmedCandidateID: levain.id)
        }
    }

    func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
        ExtractionResult(caption: evidence, candidates: Self.three)
    }

    private static let three: [PlaceCandidate] = [
        PlaceCandidate(id: "fake:levain", place: SampleData.levain, confidence: .high, reason: "Name in the caption", estimatedCost: 6),
        PlaceCandidate(id: "fake:los-tacos", place: SampleData.losTacos, confidence: .medium, reason: "Name in the caption", estimatedCost: 12),
        PlaceCandidate(id: "fake:high-line", place: SampleData.highLine, confidence: .low, reason: "Name in the caption", estimatedCost: 0),
    ]
}
#endif
