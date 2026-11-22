import Foundation

/// The organizer's "Ask friends what works" links (group plans, mode 2). Behind a protocol so tests
/// and `-skipAuth` UI tests don't need the server.
nonisolated protocol PlanRequesting: Sendable {
    /// Makes the link (GI-1). It has no answers yet.
    func create(_ draft: PlanRequestDraft) async throws -> PlanRequest
    /// The request with every friend's answer, oldest first; nil when it's gone.
    func fetch(slug: String) async throws -> PlanRequest?
    /// Stops taking answers before the deadline (GI-3).
    func close(slug: String) async throws
    /// Deletes the request and its answers; the link stops working.
    func delete(slug: String) async throws
    /// Takes a friend's answer off the request.
    func removeAnswer(slug: String, answerID: UUID) async throws
}

/// `/api/plan-requests/`, owner only: anyone else gets 404.
nonisolated struct PlanRequestClient: PlanRequesting {
    let api: PlanditAPIClient

    func create(_ draft: PlanRequestDraft) async throws -> PlanRequest {
        let body = try JSONEncoder().encode(draft)
        // The server can take a while to wake from idle, so allow a minute, as sharing does.
        let (data, http) = try await api.send("POST", path: "api/plan-requests/", body: body, timeout: 60)
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        return try decoded(data)
    }

    func fetch(slug: String) async throws -> PlanRequest? {
        let (data, http) = try await api.send("GET", path: "api/plan-requests/\(slug)/")
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        return try decoded(data)
    }

    func close(slug: String) async throws {
        let (_, http) = try await api.send("POST", path: "api/plan-requests/\(slug)/close/")
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
    }

    func delete(slug: String) async throws {
        let (_, http) = try await api.send("DELETE", path: "api/plan-requests/\(slug)/")
        // 404: already gone, which is what the organizer wanted.
        guard 200..<300 ~= http.statusCode || http.statusCode == 404 else { throw APIError.status(http.statusCode) }
    }

    func removeAnswer(slug: String, answerID: UUID) async throws {
        let (_, http) = try await api.send("DELETE", path: "api/plan-requests/\(slug)/answers/\(answerID.uuidString)/")
        // 404: already gone, which is what the organizer wanted.
        guard 200..<300 ~= http.statusCode || http.statusCode == 404 else { throw APIError.status(http.statusCode) }
    }

    private func decoded(_ data: Data) throws -> PlanRequest {
        do {
            return try PlanRequest.decode(data)
        } catch {
            throw APIError.invalidResponse
        }
    }
}

#if DEBUG
/// `-fakeRequests` (with `-fakeSharing`): a friends' input link without the server, for UI tests.
/// Maya ($20, 1 to 6 PM) stars the 2nd and 1st places; Jordan ($35, noon to 5 PM) the 2nd and 3rd.
/// `-fakeRequests clash`: Maya is free noon to 2 PM and Jordan 4 to 8 PM. Like the server, the
/// request turns built once a plan is shared with its slug, and a removed answer stays removed.
actor FakePlanRequests: PlanRequesting {
    private let sharing: FakePlanSharing
    private let clashes: Bool
    private var draft: PlanRequestDraft?
    private var closed = false
    private var removed: Set<UUID> = []

    nonisolated static let slug = "req123abcd"
    nonisolated static let mayaID = UUID(uuidString: "9C1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
    nonisolated static let jordanID = UUID(uuidString: "AD1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!

    init(sharing: FakePlanSharing, clashes: Bool) {
        self.sharing = sharing
        self.clashes = clashes
    }

    func create(_ draft: PlanRequestDraft) async throws -> PlanRequest {
        self.draft = draft
        closed = false
        removed = []
        return try await current()
    }

    func fetch(slug: String) async throws -> PlanRequest? {
        guard draft != nil, slug == Self.slug else { return nil }
        return try await current()
    }

    func close(slug: String) async throws { closed = true }

    func delete(slug: String) async throws { draft = nil }

    func removeAnswer(slug: String, answerID: UUID) async throws { removed.insert(answerID) }

    private func current() async throws -> PlanRequest {
        guard let draft else { throw APIError.status(404) }
        let published = await sharing.published
        let built = published.contains { $0.request == Self.slug }
        let places = draft.places.map(\.id)
        func place(_ index: Int) -> [UUID] { places.indices.contains(index) ? [places[index]] : [] }
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        let answers = clashes
            ? [GroupAnswer(id: Self.mayaID, name: "Maya", budget: 20, freeFrom: ClockTime(12), freeUntil: ClockTime(14),
                           stars: place(0), createdAt: at, updatedAt: at),
               GroupAnswer(id: Self.jordanID, name: "Jordan", budget: 35, freeFrom: ClockTime(16), freeUntil: ClockTime(20),
                           stars: place(1), createdAt: at, updatedAt: at)]
            : [GroupAnswer(id: Self.mayaID, name: "Maya", budget: 20, freeFrom: ClockTime(13), freeUntil: ClockTime(18),
                           stars: place(1) + place(0), createdAt: at, updatedAt: at),
               GroupAnswer(id: Self.jordanID, name: "Jordan", budget: 35, freeFrom: ClockTime(12), freeUntil: ClockTime(17),
                           stars: place(1) + place(2), createdAt: at, updatedAt: at)]
        let formatter = ISO8601DateFormatter()
        return PlanRequest(
            slug: Self.slug,
            url: URL(string: "https://plandit.app/g/\(Self.slug)")!,
            status: built ? .built : (closed ? .closed : .open),
            placeIDs: places,
            answersBy: formatter.date(from: draft.answersBy) ?? at,
            planSlug: built ? "test123abc" : nil,
            answers: answers.filter { !removed.contains($0.id) }
        )
    }
}
#endif
