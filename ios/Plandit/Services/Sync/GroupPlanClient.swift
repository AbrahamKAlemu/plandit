import Foundation

/// Group plans on the server (mode 3). Behind a protocol so tests and `-fakeGroupPlans` UI tests
/// don't need it.
///
/// Every call throws `APIError.network` when no HTTP answer came, `APIError.status` for a status
/// it doesn't expect (5xx, 503 while a lock is busy), and `APIError.invalidResponse` for a body
/// this build can't read. Auth errors come from `PlanditAPIClient`.
nonisolated protocol GroupPlanServing: Sendable {
    /// `GET /api/group-plans/`: every group this person is in.
    func list() async throws -> [GroupPlanSummary]
    /// `POST /api/group-plans/`. Throws `GroupPlanError` when refused (400, 403) or too big (413).
    func create(date: String, plan: DayPlan) async throws -> (GroupPlanDetail, etag: String?)
    /// `GET /api/group-plans/<id>/`, with `If-None-Match` only when `etag` is given.
    func fetch(_ id: UUID, etag: String?) async throws -> GroupPlanFetch
    /// `PUT /api/group-plans/<id>/`.
    func put(_ id: UUID, _ update: GroupPlanUpdate) async throws -> GroupPlanPutResult
    /// `DELETE /api/group-plans/<id>/`: true when ended, false when it was already gone (404).
    func end(_ id: UUID) async throws -> Bool
    /// nil when the link doesn't work (404; N-17: the app can't tell why).
    func preview(token: String) async throws -> GroupInvitePreview?
    /// nil when the link doesn't work. Throws `GroupPlanError.rejected` for an anonymous session.
    func join(token: String) async throws -> (GroupPlanDetail, etag: String?)?
    /// The organizer's new link; nil when the group is gone (404).
    func newInvite(_ id: UUID) async throws -> URL?
    /// Leave (your own member id) or remove someone (organizer): true when done, false when the
    /// member or group was already gone (404). Throws `GroupPlanError.rejected` for the organizer
    /// leaving.
    func removeMember(_ memberID: UUID, from id: UUID) async throws -> Bool
}

/// `/api/group-plans/` with this account's token. Paths and trailing slashes are the contract's
/// exactly; URLs are built by `PlanditAPIClient.url(for:)`, never `appending(path:)`. Plans are
/// encoded with a plain `JSONEncoder`, so dates are numbers. The ETag is this client's to send:
/// requests skip reading the URL cache (`.reloadIgnoringLocalCacheData`), and in the app they go
/// through `session`, which has no cache to store answers in.
nonisolated struct GroupPlanClient: GroupPlanServing {
    let api: PlanditAPIClient

    /// Group calls' own session. `URLSession.shared` stores answers in the shared URL cache
    /// (`Cache.db`), where plans, members' names and invite links would stay after sign-out or
    /// account deletion; this one has no cache, so a 304 to this client's `If-None-Match` comes
    /// back as a 304.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static let root = "api/group-plans/"

    /// The account's client with its `URLSession` swapped for `session`; the account's other calls
    /// keep theirs. Any other transport (a test's) is used as given.
    init(api: PlanditAPIClient) {
        if api.transport is URLSession {
            self.api = PlanditAPIClient(baseURL: api.baseURL, userID: api.userID, tokenProvider: api.tokenProvider, transport: Self.session)
        } else {
            self.api = api
        }
    }

    private struct Created: Encodable, Sendable {
        var date: String
        var plan: DayPlan
    }

    private struct Groups: Decodable {
        var groups: [GroupPlanSummary]
    }

    private struct Invite: Decodable {
        var inviteUrl: URL
    }

    func list() async throws -> [GroupPlanSummary] {
        let (data, http) = try await call("GET", Self.root)
        guard http.statusCode == 200 else { throw APIError.status(http.statusCode) }
        return try Self.decode(Groups.self, data).groups
    }

    func create(date: String, plan: DayPlan) async throws -> (GroupPlanDetail, etag: String?) {
        let body = try await Self.encodeCreated(date: date, plan: plan)
        let (data, http) = try await call("POST", Self.root, body: body)
        switch http.statusCode {
        case 200, 201: return (try await Self.decodeDetail(data), Self.etag(http))
        case 400, 403: throw GroupPlanError.rejected(Self.message(in: data))
        case 413: throw GroupPlanError.tooLarge(Self.message(in: data))
        default: throw APIError.status(http.statusCode)
        }
    }

    func fetch(_ id: UUID, etag: String?) async throws -> GroupPlanFetch {
        var headers: [String: String] = [:]
        if let etag { headers["If-None-Match"] = etag }
        let (data, http) = try await call("GET", Self.path(id), headers: headers)
        switch http.statusCode {
        case 200: return .plan(try await Self.decodeDetail(data), etag: Self.etag(http))
        case 304: return .notModified
        case 404: return .gone
        default: throw APIError.status(http.statusCode)
        }
    }

    func put(_ id: UUID, _ update: GroupPlanUpdate) async throws -> GroupPlanPutResult {
        let body = try await Self.encode(update)
        let (data, http) = try await call("PUT", Self.path(id), body: body)
        switch http.statusCode {
        case 200: return .saved(try Self.decode(GroupPlanSaved.self, data), etag: Self.etag(http))
        case 409: return .conflict(try await Self.decodeConflict(data), etag: Self.etag(http))
        case 404: return .gone
        case 400, 403: return .rejected(Self.message(in: data))
        case 413: return .tooLarge(Self.message(in: data))
        default: throw APIError.status(http.statusCode)
        }
    }

    func end(_ id: UUID) async throws -> Bool {
        let (data, http) = try await call("DELETE", Self.path(id))
        return try Self.done(http, data)
    }

    func preview(token: String) async throws -> GroupInvitePreview? {
        let (data, http) = try await call("GET", "\(Self.root)invites/\(Self.escaped(token))/")
        switch http.statusCode {
        case 200: return try Self.decode(GroupInvitePreview.self, data)
        case 404: return nil
        default: throw APIError.status(http.statusCode)
        }
    }

    func join(token: String) async throws -> (GroupPlanDetail, etag: String?)? {
        let (data, http) = try await call("POST", "\(Self.root)invites/\(Self.escaped(token))/join")
        switch http.statusCode {
        case 200, 201: return (try await Self.decodeDetail(data), Self.etag(http))
        case 404: return nil
        case 400, 403: throw GroupPlanError.rejected(Self.message(in: data))
        default: throw APIError.status(http.statusCode)
        }
    }

    func newInvite(_ id: UUID) async throws -> URL? {
        // No trailing slash, as the contract writes it.
        let (data, http) = try await call("POST", "\(Self.path(id))invite")
        switch http.statusCode {
        case 200: return try Self.decode(Invite.self, data).inviteUrl
        case 404: return nil
        default: throw APIError.status(http.statusCode)
        }
    }

    func removeMember(_ memberID: UUID, from id: UUID) async throws -> Bool {
        let (data, http) = try await call("DELETE", "\(Self.path(id))members/\(memberID.uuidString)/")
        return try Self.done(http, data)
    }

    // MARK: - Internals

    private func call(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await api.send(method, path: path, body: body, headers: headers, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    /// `api/group-plans/<ID>/`. The server matches ids as text and parses them, so case doesn't matter.
    private static func path(_ id: UUID) -> String { "\(root)\(id.uuidString)/" }

    private static func escaped(_ token: String) -> String {
        token.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")) ?? token
    }

    /// The ETag exactly as the server sent it, weak prefix and quotes included.
    private static func etag(_ http: HTTPURLResponse) -> String? {
        http.value(forHTTPHeaderField: "ETag")
    }

    /// 204 (or 200) done, 404 already gone, 400/403 refused with the server's words.
    private static func done(_ http: HTTPURLResponse, _ data: Data) throws -> Bool {
        switch http.statusCode {
        case 200, 204: return true
        case 404: return false
        case 400, 403: throw GroupPlanError.rejected(message(in: data))
        default: throw APIError.status(http.statusCode)
        }
    }

    /// Group plans carry a `DayPlan`, whose Codable conformance belongs to the main actor (the app's
    /// default isolation). Encoding and decoding them hops there: Xcode 26's compiler (Swift 6.3)
    /// rejects using that conformance from this nonisolated client otherwise.
    @MainActor private static func decodeDetail(_ data: Data) throws -> GroupPlanDetail {
        try decode(GroupPlanDetail.self, data)
    }

    @MainActor private static func decodeConflict(_ data: Data) throws -> GroupPlanConflict {
        try decode(GroupPlanConflict.self, data)
    }

    @MainActor private static func encode(_ update: GroupPlanUpdate) throws -> Data {
        try JSONEncoder().encode(update)
    }

    @MainActor private static func encodeCreated(date: String, plan: DayPlan) throws -> Data {
        try JSONEncoder().encode(Created(date: date, plan: plan))
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// `{"detail": "..."}`, or the first message of a field error (`{"plan": ["..."]}`), fields
    /// in name order.
    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String { return detail }
        for key in object.keys.sorted() {
            if let text = object[key] as? String { return text }
            if let texts = object[key] as? [Any], let first = texts.first as? String { return first }
        }
        return nil
    }
}
