import CoreLocation
import Foundation
import Observation

/// App-wide state: today's plan, saved posts, and the profile.
/// Persisted locally after every change; backed by sample data on first launch.
@Observable
final class PlanditStore {
    var today: DayPlan
    var saved: [SavedPost]
    var profile: UserProfile
    var stats: UserStats
    var pastPlans: [PastPlan]
    var visited: [Place]
    /// Real walking geometry per leg, filled in by `loadRoutes()`.
    private(set) var legPaths: [UUID: [CLLocationCoordinate2D]] = [:]

    @ObservationIgnored private let extractor: any PlaceExtracting
    @ObservationIgnored private let routes = RouteService()
    @ObservationIgnored private let storage: SnapshotStore?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(
        today: DayPlan,
        saved: [SavedPost],
        profile: UserProfile,
        stats: UserStats,
        pastPlans: [PastPlan],
        visited: [Place],
        extractor: any PlaceExtracting = StubPlaceExtractor(),
        storage: SnapshotStore? = nil
    ) {
        self.today = today
        self.saved = saved
        self.profile = profile
        self.stats = stats
        self.pastPlans = pastPlans
        self.visited = visited
        self.extractor = extractor
        self.storage = storage
        for post in saved where post.status == .processing {
            startExtraction(post.id)
        }
    }

    /// What the user left last time, rolled over to today; the sample data on first launch
    /// or when launched with `-resetData`.
    static func load(storage: SnapshotStore = .default, extractor: any PlaceExtracting = StubPlaceExtractor()) -> PlanditStore {
        if CommandLine.arguments.contains("-resetData") { storage.reset() }
        guard let snapshot = storage.load() else { return sample(storage: storage, extractor: extractor) }
        let store = PlanditStore(
            today: snapshot.today,
            saved: snapshot.saved,
            profile: snapshot.profile,
            stats: SampleData.stats, // still mock; see ios/README.md
            pastPlans: snapshot.pastPlans,
            visited: snapshot.visited,
            extractor: extractor,
            storage: storage
        )
        store.rollOverIfNeeded()
        return store
    }

    static func sample(storage: SnapshotStore? = nil, extractor: any PlaceExtracting = StubPlaceExtractor()) -> PlanditStore {
        PlanditStore(
            today: SampleData.dayPlan,
            saved: SampleData.savedPosts,
            profile: SampleData.profile,
            stats: SampleData.stats,
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

    /// Walking path if loaded, otherwise a straight line (MapKit has no transit geometry).
    func path(for leg: TravelLeg) -> [CLLocationCoordinate2D] {
        if let path = legPaths[leg.id] { return path }
        guard let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { return [] }
        return [from.place.coordinate, to.place.coordinate]
    }

    // MARK: - Routes

    func loadRoutes() async {
        for leg in today.legs where leg.mode == .walk && legPaths[leg.id] == nil {
            guard let from = stop(id: leg.fromStopID), let to = stop(id: leg.toStopID) else { continue }
            legPaths[leg.id] = await routes.walkingPath(from: from.place.coordinate, to: to.place.coordinate)
        }
    }

    // MARK: - Day rollover

    /// A plan belongs to one date. On the first launch of a new day, file the old plan under
    /// recent plans and start today empty with the default budget.
    func rollOverIfNeeded(now: Date = .now) {
        guard !Calendar.current.isDate(today.date, inSameDayAs: now) else { return }
        if !today.stops.isEmpty {
            pastPlans.insert(
                PastPlan(title: today.title, date: today.date, stopCount: today.stops.count, cost: today.totalCost),
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
        ShareInbox.drain().map { save(url: $0.url, sharedText: $0.sharedText) }
    }

    @discardableResult
    func save(url: URL, sharedText: String? = nil) -> UUID {
        if let existing = saved.first(where: { $0.url == url }) { return existing.id }
        let post = SavedPost(url: url, platform: SourcePlatform(url: url), caption: sharedText, savedAt: .now, status: .processing)
        saved.insert(post, at: 0)
        persist()
        startExtraction(post.id)
        return post.id
    }

    func retryExtraction(_ id: UUID) {
        update(id) { $0.status = .processing }
        startExtraction(id)
    }

    func removePost(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func startExtraction(_ id: UUID) {
        Task { await extract(id) }
    }

    private func extract(_ id: UUID) async {
        guard let post = post(id: id) else { return }
        do {
            let result = try await extractor.extract(from: post.url, sharedText: post.caption)
            update(id) { $0.apply(result) }
        } catch {
            update(id) { $0.status = .failed }
        }
    }

    private func update(_ id: UUID, _ change: (inout SavedPost) -> Void) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        change(&saved[index])
        persist()
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
            estimatedCost: post.estimatedCost ?? 0,
            note: "Added from your saved \(post.platform.displayName) post.",
            sourcePostID: post.id,
            status: .upcoming
        )
        today.stops.append(stop)
        rebuildLegs()
        persist()
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
            today.stops = locked + outcome.stops
            today.legs = today.legs.filter { lockedIDs.contains($0.fromStopID) && lockedIDs.contains($0.toStopID) } + outcome.legs
        }
        today.budget = budget
        if mode == .replace || lockedStops.isEmpty {
            today.title = Self.title(for: today.stops)
        }
        persist()
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
            return DayPlanner.Request(candidates: picked, start: start, budget: budget)
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
                alreadySpent: locked.reduce(0) { $0 + $1.estimatedCost } + lockedLegCost
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

    private var snapshot: StoreSnapshot {
        StoreSnapshot(saved: saved, today: today, profile: profile, pastPlans: pastPlans, visited: visited)
    }

    /// Coalesces bursts of changes into one write a moment later.
    private func persist() {
        guard let storage else { return }
        let snapshot = snapshot
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try storage.save(snapshot) } catch { print("Plandit: could not save state: \(error)") }
        }
    }

    /// Writes any pending change immediately (call when the app leaves the foreground).
    func flush() {
        guard let storage else { return }
        pendingSave?.cancel()
        pendingSave = nil
        try? storage.save(snapshot)
    }
}
