import Foundation

/// Friends' answers on the organizer's shared plan (group plans, mode 1). Behind a protocol so tests
/// and `-skipAuth` UI tests don't need the server.
nonisolated protocol ShareAnswersFetching: Sendable {
    /// Every answer on the link, oldest first.
    func answers(slug: String) async throws -> [ShareAnswer]
    /// Takes one off the link: it's gone from the page at once.
    func remove(slug: String, answerID: UUID) async throws
}

/// `GET /api/shares/<slug>/answers/` and `DELETE /api/shares/<slug>/answers/<id>/`, owner only.
nonisolated struct ShareAnswersClient: ShareAnswersFetching {
    let api: PlanditAPIClient

    /// A 404 is "no answers": a server without the endpoint yet (today's production API), or a
    /// link that's gone. Neither is something to show the organizer.
    func answers(slug: String) async throws -> [ShareAnswer] {
        let (data, http) = try await api.send("GET", path: "api/shares/\(slug)/answers/")
        if http.statusCode == 404 { return [] }
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        do {
            return try ShareAnswer.decodeList(data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    func remove(slug: String, answerID: UUID) async throws {
        let (_, http) = try await api.send("DELETE", path: "api/shares/\(slug)/answers/\(answerID.uuidString)/")
        // 404: already gone, which is what the organizer wanted.
        guard 200..<300 ~= http.statusCode || http.statusCode == 404 else { throw APIError.status(http.statusCode) }
    }
}

#if DEBUG
/// `-fakeAnswers` (with `-fakeSharing`): fixed answers for UI tests, without the server. On the
/// first stop of the last published page that has swaps, Maya picks its first one and Jordan would
/// swap it without a pick; Sam can't make it. Like the server, swaps for stops no longer on the
/// page are dropped, and a removed answer stays removed.
actor FakeShareAnswers: ShareAnswersFetching {
    private let sharing: FakePlanSharing
    private var target: (stop: UUID, pick: UUID?)?
    private var removed: Set<UUID> = []

    nonisolated static let mayaID = UUID(uuidString: "6F1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
    nonisolated static let jordanID = UUID(uuidString: "7A1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
    nonisolated static let samID = UUID(uuidString: "8B1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!

    init(sharing: FakePlanSharing) {
        self.sharing = sharing
    }

    func answers(slug: String) async throws -> [ShareAnswer] {
        guard let page = await sharing.published.last else { return [] }
        if target == nil, let stop = page.stops.first(where: { !($0.alternates ?? []).isEmpty }) {
            target = (stop.id, stop.alternates?.first?.id)
        }
        var swapsMaya: [UUID: UUID?] = [:]
        var swapsJordan: [UUID: UUID?] = [:]
        if let target, page.stops.contains(where: { $0.id == target.stop }) {
            swapsMaya[target.stop] = .some(target.pick)
            swapsJordan[target.stop] = .some(nil)
        }
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        return [
            ShareAnswer(id: Self.mayaID, name: "Maya", status: .in, swaps: swapsMaya, createdAt: at, updatedAt: at),
            ShareAnswer(id: Self.jordanID, name: "Jordan", status: .in, swaps: swapsJordan, createdAt: at, updatedAt: at),
            ShareAnswer(id: Self.samID, name: "Sam", status: .out, swaps: [:], createdAt: at, updatedAt: at),
        ].filter { !removed.contains($0.id) }
    }

    func remove(slug: String, answerID: UUID) async throws {
        removed.insert(answerID)
    }
}
#endif
