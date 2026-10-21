import CoreLocation
import Foundation
import Observation

private struct SavedPlacePersistenceError: LocalizedError {
    var errorDescription: String? {
        "We couldn't save that change. Try again."
    }
}

/// App-wide state: today's plan, saved posts, and the profile. Backed by sample data for now.
@Observable
@MainActor
final class PlanditStore {
    var today: DayPlan
    var saved: [SavedPost]
    var profile: UserProfile
    var stats: UserStats
    var pastPlans: [PastPlan]
    var visited: [Place]
    var savedErrorMessage: String?
    /// Real walking geometry per leg, filled in by `loadRoutes()`.
    private(set) var legPaths: [UUID: [CLLocationCoordinate2D]] = [:]

    @ObservationIgnored private let extractor: any PlaceExtracting
    @ObservationIgnored private let persistence: SavedPostPersistence?
    @ObservationIgnored private let videoExtractor: VideoEvidenceExtractor
    @ObservationIgnored private let routes = RouteService()

    init(
        today: DayPlan,
        saved: [SavedPost],
        profile: UserProfile,
        stats: UserStats,
        pastPlans: [PastPlan],
        visited: [Place],
        extractor: any PlaceExtracting = FixturePlaceExtractor(),
        persistence: SavedPostPersistence? = nil,
        videoExtractor: VideoEvidenceExtractor = VideoEvidenceExtractor()
    ) {
        self.today = today
        self.saved = saved
        self.profile = profile
        self.stats = stats
        self.pastPlans = pastPlans
        self.visited = visited
        self.extractor = extractor
        self.persistence = persistence
        self.videoExtractor = videoExtractor
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

    static func live() -> PlanditStore {
        do {
            let persistence = try SavedPostPersistence()
            if ProcessInfo.processInfo.arguments.contains("-resetSavedData") {
                try persistence.deleteAll()
            }
            return PlanditStore(
                today: SampleData.dayPlan,
                saved: try persistence.load(),
                profile: SampleData.profile,
                stats: SampleData.stats,
                pastPlans: SampleData.pastPlans,
                visited: SampleData.visitedPlaces,
                persistence: persistence
            )
        } catch {
            fatalError("Unable to initialize saved-place persistence: \(error)")
        }
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
        for share in ShareInbox.pending() {
            do {
                _ = try save(url: share.url, sharedText: share.sharedText)
                ShareInbox.acknowledge(share.id)
            } catch {
                break
            }
        }
    }

    @discardableResult
    func save(url: URL, sharedText: String? = nil) throws -> UUID {
        let supported = try SupportedSocialURL(url)
        if let existing = saved.first(where: { $0.canonicalURL == supported.canonicalURL }) {
            try persist(existing)
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
        try persist(post)
        saved.insert(post, at: 0)
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
        guard let canonicalURL = post(id: id)?.canonicalURL else { return }
        do {
            try persistence?.delete(canonicalURL: canonicalURL)
            saved.removeAll { $0.id == id }
        } catch {
            savedErrorMessage = "We couldn't remove this save. Try again."
        }
    }

    func confirm(postID: UUID, candidateID: String) {
        updateAndPersist(postID) { post in
            guard let candidate = post.candidates.first(where: { $0.id == candidateID }) else { return }
            post.place = candidate.place
            post.estimatedCost = candidate.estimatedCost
            post.status = candidate.place.hours == nil ? .needsReview : .ready
            post.candidates = []
        }
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
        try persist(post)
        saved.insert(post, at: 0)

        let evidence: VideoEvidence
        do {
            evidence = try await videoExtractor.extract(from: fileURL)
        } catch let extractionError {
            do {
                try persistence?.delete(canonicalURL: sourceURL)
                saved.removeAll { $0.id == id }
            } catch {
                savedErrorMessage = "We couldn't clean up the failed video save. Try again."
                if let index = saved.firstIndex(where: { $0.id == id }) {
                    saved[index].status = .failed
                    saved[index].failureMessage = extractionError.localizedDescription
                }
                throw SavedPlacePersistenceError()
            }
            throw extractionError
        }
        guard updateAndPersist(id, mutation: {
            $0.caption = evidence.text
            $0.status = .processing
            $0.failureMessage = evidence.transcriptionNotice
        }) else {
            throw SavedPlacePersistenceError()
        }
        await resolveEvidence(
            postID: id,
            text: evidence.text,
            noCandidatesMessage: evidence.transcriptionNotice
                ?? "We couldn't confidently match this video. Review the extracted details and try again."
        )
        return id
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
        Task { await extract(id) }
    }

    private func extract(_ id: UUID) async {
        guard let post = post(id: id) else { return }
        do {
            let result = try await extractor.extract(from: post.url, sharedText: post.caption)
            updateAndPersist(id) { $0.apply(result) }
        } catch {
            updateAndPersist(id) {
                $0.status = .failed
                $0.failureMessage = "We couldn't read this source. Add details or try again."
            }
        }
    }

    private func resolveEvidence(
        postID: UUID,
        text: String,
        noCandidatesMessage: String? = nil
    ) async {
        guard let post = post(id: postID) else { return }
        do {
            let result = try await extractor.resolve(evidence: text, platform: post.platform)
            updateAndPersist(postID) {
                $0.apply(result)
                if result.candidates.isEmpty {
                    $0.failureMessage = noCandidatesMessage
                }
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
        var updated = saved[index]
        mutation(&updated)
        do {
            try persist(updated)
            saved[index] = updated
            return true
        } catch {
            savedErrorMessage = "We couldn't save that change. Try again."
            saved[index].status = .failed
            saved[index].failureMessage = "This change wasn't saved. Try again."
            return false
        }
    }

    private func persist(_ post: SavedPost) throws {
        try persistence?.upsert(post)
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
