import Foundation
@testable import Plandit

/// What the "Ask friends what works" tests share: four saved places, 11 AM today (before the
/// default noon to 8 PM range), and a store with a link made.
@MainActor enum AskFriendsFixtures {
    static var places: [SavedPost] {
        [SampleData.highLinePost, SampleData.tacosPost, SampleData.levainPost, SampleData.littleIslandPost]
    }

    /// 11 AM today, before the range starts.
    static var elevenAM: Date {
        Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!
    }

    static func draft(on day: Date? = nil, calendar: Calendar = .current) -> PlanRequestDraft {
        PlanRequestDraft(posts: places, day: day ?? elevenAM, start: ClockTime(12), end: ClockTime(20),
                         answersBy: elevenAM.addingTimeInterval(3600), calendar: calendar)
    }

    static func makeStore(sharing: FakePlanSharing = FakePlanSharing()) -> PlanditStore {
        let store = PlanditStore(today: SampleData.dayPlan, saved: SampleData.savedPosts, profile: SampleData.profile,
                                 pastPlans: [], visited: [], storage: nil)
        store.sharing = sharing
        return store
    }

    /// A store with a link for `day` (today by default) on a server the test sets.
    static func requestedStore(on day: Date? = nil, sharing: FakePlanSharing = FakePlanSharing())
        async throws -> (PlanditStore, RecordingRequests) {
        let store = makeStore(sharing: sharing)
        let requests = RecordingRequests()
        store.requestClient = requests
        try await store.createPlanRequest(draft(on: day), answersBy: elevenAM.addingTimeInterval(3600))
        return (store, requests)
    }

    static func answer(_ name: String, budget: Int, _ from: Int, _ until: Int, stars: [UUID] = []) -> GroupAnswer {
        GroupAnswer(id: UUID(), name: name, budget: budget, freeFrom: ClockTime(from), freeUntil: ClockTime(until),
                    stars: stars, createdAt: Date(), updatedAt: Date())
    }

    /// The plan from everyone's inputs, with the organizer's defaults.
    static func plan(_ store: PlanditStore) -> GroupInputs.Plan? {
        guard let link = store.planRequest,
              case .ready(let plan)? = store.groupInputs(organizer: store.organizerInputs(for: link), leftOut: []) else { return nil }
        return plan
    }
}

/// A server the test sets, recording what the store asked for.
actor RecordingRequests: PlanRequesting {
    private var request: PlanRequest?
    private var failsNext = false
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var fetches = 0
    private(set) var removed: [UUID] = []
    private(set) var closed: [String] = []
    private(set) var deleted: [String] = []
    var isHolding: Bool { held != nil }

    func setAnswers(_ answers: [GroupAnswer]) { request?.answers = answers }
    func setStatus(_ status: PlanRequest.Status, planSlug: String? = nil) {
        request?.status = status
        request?.planSlug = planSlug
    }
    func setGone() { request = nil }
    func failNext() { failsNext = true }
    /// The next fetch waits for `release()`, then answers with what was set when it was asked.
    func holdNext() { holdsNext = true }
    func release() {
        held?.resume()
        held = nil
    }

    func create(_ draft: PlanRequestDraft) async throws -> PlanRequest {
        let created = PlanRequest(slug: "req1", url: URL(string: "https://plandit.app/g/req1")!, status: .open,
                                  placeIDs: draft.places.map(\.id), answersBy: Date(), planSlug: nil, answers: [])
        request = created
        return created
    }

    func fetch(slug: String) async throws -> PlanRequest? {
        fetches += 1
        if failsNext {
            failsNext = false
            throw APIError.network
        }
        let current = request
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { held = $0 }
        }
        return current
    }

    func close(slug: String) async throws {
        closed.append(slug)
        request?.status = .closed
    }

    func delete(slug: String) async throws {
        deleted.append(slug)
        request = nil
    }

    func removeAnswer(slug: String, answerID: UUID) async throws {
        removed.append(answerID)
        request?.answers.removeAll { $0.id == answerID }
    }
}
