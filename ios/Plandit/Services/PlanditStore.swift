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

    /// Computed from real past plans and visited places; never sample numbers.
    var stats: UserStats { UserStats.compute(pastPlans: pastPlans, visited: visited) }

    /// Called after every successful local write with what was written. The sync coordinator hooks in here.
    @ObservationIgnored var onChange: ((StoreSnapshot) -> Void)?
    /// Usage events for the metrics API. Injected so tests can capture them; nil drops them.
    @ObservationIgnored var events: ((UsageEvent) -> Void)?

    @ObservationIgnored private let extractor: any PlaceExtracting
    @ObservationIgnored private let videoExtractor: VideoEvidenceExtractor
    @ObservationIgnored private let routes: any RouteProviding
    /// Apple Maps answers by mode and place pair, so a leg's options load once.
    @ObservationIgnored private var liveRoutes: [String: RouteInfo] = [:]
    @ObservationIgnored private let storage: SnapshotStore?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// Posts whose extraction or evidence lookup is still running; never started twice.
    @ObservationIgnored private var inFlight: Set<UUID> = []
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
        videoExtractor: VideoEvidenceExtractor = VideoEvidenceExtractor(),
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
        self.events = events
        for post in saved where post.status == .processing {
            startExtraction(post.id)
        }
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
        legPaths = [:]
        persistNow()
        rollOverIfNeeded()
        for post in saved where post.status == .processing {
            startExtraction(post.id)
        }
        Task { await loadRoutes() }
    }

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
    static func load(storage: SnapshotStore = .default, extractor: any PlaceExtracting = FixturePlaceExtractor()) -> PlanditStore {
        if CommandLine.arguments.contains("-resetData") { storage.reset() }
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
    func travelOptions(forLeg id: UUID) -> [TravelOption] {
        guard let leg = today.legs.first(where: { $0.id == id }),
              let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return [] }
        return TravelMode.choices.map { mode in
            let live = liveRoutes[Self.routeKey(mode, from: from.place, to: to.place)]
            return TravelOption(leg: Self.leg(mode, live: live, replacing: leg, from: from.place, to: to.place), isLive: live != nil)
        }
    }

    /// Asks Apple Maps for all three ways of making this trip.
    func loadTravelOptions(forLeg id: UUID) async {
        guard let leg = today.legs.first(where: { $0.id == id }),
              let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return }
        for mode in TravelMode.choices {
            _ = await liveRoute(mode, from: from.place, to: to.place)
        }
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
        today.setTime(ofStop: id, start: start, durationMinutes: durationMinutes, moveLaterStops: moveLaterStops)
        persist()
    }

    /// Every trip still ahead goes this way: "Drive everywhere", "Take the subway".
    func chooseTravelForRestOfDay(_ mode: TravelMode) {
        for leg in today.legs where today.state(of: leg) != .completed {
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
                    walkingMiles: today.walkingMiles
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
    @discardableResult
    func ingestPendingShares() -> [UUID] {
        var ids: [UUID] = []
        for share in ShareInbox.pending() {
            do {
                ids.append(try save(url: share.url, sharedText: share.sharedText))
                ShareInbox.acknowledge(share.id)
            } catch {
                savedErrorMessage = error.localizedDescription
            }
        }
        return ids
    }

    @discardableResult
    func save(url: URL, sharedText: String? = nil) throws -> UUID {
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
            caption: sharedText,
            savedAt: .now,
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
        if confirmed { events?(.placeSaved) }
        return confirmed
    }

    func submitEvidence(postID: UUID, text: String) {
        guard updateAndPersist(postID, mutation: {
            $0.caption = text
            $0.status = .processing
            $0.failureMessage = nil
        }) else { return }
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
        do {
            try await applyVideoEvidence(postID: postID, fileURL: fileURL)
        } catch {
            updateAndPersist(postID) {
                $0.status = .needsEvidence
                $0.failureMessage = error.localizedDescription
            }
            throw error
        }
    }

    func removeExpiredTemporaryMedia() {
        do {
            try TemporaryMediaStore().removeExpiredFiles(
                olderThan: Date().addingTimeInterval(-24 * 60 * 60)
            )
        } catch {
            assertionFailure("Temporary media cleanup failed: \(error)")
        }
    }

    private func startExtraction(_ id: UUID) {
        guard inFlight.insert(id).inserted else { return }
        Task { await extract(id) }
    }

    private func extract(_ id: UUID) async {
        defer { inFlight.remove(id) }
        guard let post = post(id: id) else { return }
        do {
            let result = try await extractor.extract(from: post.url, sharedText: post.caption)
            let updated = applyExtractionResult(result, to: id)
            if updated, result.autoConfirmedCandidateID != nil {
                events?(.placeSaved)
            }
        } catch let error as DevelopmentSocialEvidenceError {
            updateAndPersist(id) {
                $0.status = .needsEvidence
                $0.failureMessage = error.localizedDescription
            }
        } catch {
            updateAndPersist(id) {
                $0.status = .failed
                $0.failureMessage = "We couldn't read this source. Add details or try again."
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
            visited: visited
        )
        try storage.save(snapshot)
        onChange?(snapshot)
    }

    // MARK: - Today's plan

    /// Appends a saved place to the end of today. TODO: let the planner re-optimize order, time and budget.
    @discardableResult
    func addToToday(_ postID: UUID) -> UUID? {
        guard let post = post(id: postID), let place = post.place, !isInToday(post) else { return nil }
        let start = (today.stops.last?.end ?? .now).addingTimeInterval(20 * 60)
        let stop = PlanStop(
            place: place,
            start: start,
            durationMinutes: 60,
            estimatedCost: post.plannedCost ?? 0,
            note: "Added from your saved \(post.platform.displayName) post.",
            sourcePostID: post.id,
            status: .upcoming
        )
        today.stops.append(stop)
        rebuildLegs()
        persist()
        events?(.planBuilt)
        Task { await loadRoutes() }
        return stop.id
    }

    func removeStop(_ id: UUID) {
        today.stops.removeAll { $0.id == id }
        rebuildLegs()
        persist()
    }

    /// "I'm here": this stop is happening now, everything before it is done, everything after is still planned.
    func arrive(at stopID: UUID) {
        guard let index = stopIndex(id: stopID) else { return }
        setStatuses(doneThrough: index - 1, now: index)
    }

    /// "Done here": this stop and everything before it are done; the next stop becomes "now".
    func complete(_ stopID: UUID) {
        guard let index = stopIndex(id: stopID) else { return }
        setStatuses(doneThrough: index, now: index + 1 < today.stops.count ? index + 1 : nil)
    }

    private func setStatuses(doneThrough: Int, now: Int?) {
        for index in today.stops.indices {
            today.stops[index].status = index <= doneThrough ? .done : (index == now ? .now : .upcoming)
        }
        persist()
    }

    /// Keeps existing legs between consecutive stops and estimates any new pairs.
    private func rebuildLegs() {
        let existing = today.legs
        today.legs = zip(today.stops, today.stops.dropFirst()).map { from, to in
            existing.first { $0.fromStopID == from.id && $0.toStopID == to.id } ?? .estimate(from: from, to: to, travel: travelPreference)
        }
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

    private func basePlanRequest(postIDs: [UUID], start: Date, budget: Double, mode: PlanMode) -> DayPlanner.Request {
        var seen = Set<UUID>()
        let picked = postIDs.filter { seen.insert($0).inserted }.compactMap { post(id: $0) }.compactMap(PlanCandidate.init(post:))
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

    // MARK: - Profile

    func updateProfile(_ change: (inout UserProfile) -> Void) {
        change(&profile)
        if today.stops.isEmpty { today.budget = profile.defaultBudget }
        persist()
    }

    // MARK: - Persistence

    var snapshot: StoreSnapshot {
        StoreSnapshot(saved: saved, today: today, profile: profile, pastPlans: pastPlans, visited: visited)
    }

    /// The current state in the exact JSON shape the file and the cloud copy use.
    var encodedSnapshot: Data? { try? SnapshotStore.encode(snapshot) }

    /// Coalesces bursts of changes into one write a moment later.
    private func persist() {
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
        guard let storage, !isClosed else { return }
        let snapshot = snapshot
        guard (try? storage.save(snapshot)) != nil else { return }
        onChange?(snapshot)
    }
}
