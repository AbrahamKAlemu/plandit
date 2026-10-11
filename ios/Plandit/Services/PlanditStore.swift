import CoreLocation
import Foundation
import Observation

/// App-wide state: today's plan, saved posts, and the profile. Backed by sample data for now.
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

    init(
        today: DayPlan,
        saved: [SavedPost],
        profile: UserProfile,
        stats: UserStats,
        pastPlans: [PastPlan],
        visited: [Place],
        extractor: any PlaceExtracting = StubPlaceExtractor()
    ) {
        self.today = today
        self.saved = saved
        self.profile = profile
        self.stats = stats
        self.pastPlans = pastPlans
        self.visited = visited
        self.extractor = extractor
        for post in saved where post.status == .processing {
            startExtraction(post.id)
        }
    }

    static func sample() -> PlanditStore {
        PlanditStore(
            today: SampleData.dayPlan,
            saved: SampleData.savedPosts,
            profile: SampleData.profile,
            stats: SampleData.stats,
            pastPlans: SampleData.pastPlans,
            visited: SampleData.visitedPlaces
        )
    }

    // MARK: - Lookup

    func stop(id: UUID) -> PlanStop? { today.stop(id: id) }

    func stopNumber(id: UUID) -> Int? {
        today.stops.firstIndex { $0.id == id }.map { $0 + 1 }
    }

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

    // MARK: - Saved posts

    /// Pulls in anything the share extension queued while the app was in the background.
    func ingestPendingShares() {
        for share in ShareInbox.drain() {
            save(url: share.url, sharedText: share.sharedText)
        }
    }

    @discardableResult
    func save(url: URL, sharedText: String? = nil) -> UUID {
        if let existing = saved.first(where: { $0.url == url }) { return existing.id }
        let post = SavedPost(url: url, platform: SourcePlatform(url: url), caption: sharedText, savedAt: .now, status: .processing)
        saved.insert(post, at: 0)
        startExtraction(post.id)
        return post.id
    }

    func retryExtraction(_ id: UUID) {
        update(id) { $0.status = .processing }
        startExtraction(id)
    }

    func removePost(_ id: UUID) {
        saved.removeAll { $0.id == id }
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
    }

    // MARK: - Today's plan

    /// Appends a saved place to the end of today. TODO: let the planner re-optimize order, time and budget.
    func addToToday(_ postID: UUID) {
        guard let post = post(id: postID), let place = post.place, !isInToday(post) else { return }
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
        Task { await loadRoutes() }
    }

    func removeStop(_ id: UUID) {
        today.stops.removeAll { $0.id == id }
        rebuildLegs()
    }

    /// Keeps existing legs between consecutive stops and estimates any new pairs.
    private func rebuildLegs() {
        let existing = today.legs
        today.legs = zip(today.stops, today.stops.dropFirst()).map { from, to in
            existing.first { $0.fromStopID == from.id && $0.toStopID == to.id } ?? .estimate(from: from, to: to)
        }
    }
}
