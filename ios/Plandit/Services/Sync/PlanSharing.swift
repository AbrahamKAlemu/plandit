import Foundation

/// Publishing a plan as a link and taking it down. Behind a protocol so tests and `-skipAuth`
/// UI tests don't need the server.
protocol PlanSharing: Sendable {
    /// Creates the plan's link, or updates the page if it already has one. Returns its address.
    func publish(_ payload: SharedPlanPayload) async throws -> (slug: String, url: URL)
    /// Stops sharing: the link stops working.
    func unpublish(slug: String) async throws
}

/// `POST /api/shares/` and `DELETE /api/shares/<slug>/`.
nonisolated struct SharedPlanClient: PlanSharing {
    let api: PlanditAPIClient

    private struct Created: Decodable {
        let slug: String
        let url: URL
    }

    func publish(_ payload: SharedPlanPayload) async throws -> (slug: String, url: URL) {
        let body = try JSONEncoder().encode(payload)
        // The server can take a while to wake from idle, so allow a minute.
        let (data, http) = try await api.send("POST", path: "api/shares/", body: body, timeout: 60)
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        let created = try JSONDecoder().decode(Created.self, from: data)
        return (created.slug, created.url)
    }

    func unpublish(slug: String) async throws {
        let (_, http) = try await api.send("DELETE", path: "api/shares/\(slug)/")
        // 404: already gone, which is what the person wanted.
        guard 200..<300 ~= http.statusCode || http.statusCode == 404 else { throw APIError.status(http.statusCode) }
    }
}

#if DEBUG
/// `-fakeSharing`: a link without the network, for UI tests. `-fakeSharing fail` always fails.
actor FakePlanSharing: PlanSharing {
    private let fails: Bool
    private(set) var published: [SharedPlanPayload] = []
    private(set) var unpublished: [String] = []

    init(fails: Bool = false) { self.fails = fails }

    func publish(_ payload: SharedPlanPayload) async throws -> (slug: String, url: URL) {
        if fails { throw APIError.network }
        published.append(payload)
        return ("test123abc", URL(string: "https://plandit.app/p/test123abc")!)
    }

    func unpublish(slug: String) async throws {
        if fails { throw APIError.network }
        unpublished.append(slug)
    }
}
#endif
