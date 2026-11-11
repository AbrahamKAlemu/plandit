import Foundation

nonisolated enum APIError: Error, Equatable, Sendable {
    case network
    case status(Int)
    case invalidResponse
}

/// Authenticated calls to the Django API (`/api/me/...`) for one account. Every request carries
/// that account's Supabase access token; a 401 forces one refresh and one retry, and a second
/// 401 ends the session.
nonisolated struct PlanditAPIClient: Sendable {
    let baseURL: URL
    let userID: String
    let tokenProvider: any AccessTokenProviding
    let transport: any HTTPTransport

    init(
        baseURL: URL,
        userID: String,
        tokenProvider: any AccessTokenProviding,
        transport: any HTTPTransport = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.userID = userID
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    func url(for path: String) -> URL {
        // Not `appending(path:)`: on iOS 18 it doubles a trailing slash ("snapshot//"), and the API
        // answers 404 to that.
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + path) ?? baseURL.appending(path: path)
    }

    /// Throws `AuthError.accountDeleted` when the API says the account is gone (after telling the
    /// token provider), `AuthError.sessionExpired` when a refreshed token is still refused,
    /// `APIError.network` when the request never got an HTTP answer. Any other status is
    /// returned as-is for the caller to interpret.
    func send(
        _ method: String,
        path: String,
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        let token = try await tokenProvider.accessToken(for: userID, rejected: nil)
        let first = try await perform(method, path: path, body: body, timeout: timeout, token: token)
        guard first.1.statusCode == 401 else { return first }
        try await failIfAccountDeleted(first.0)
        // One forced refresh, one retry.
        let fresh = try await tokenProvider.accessToken(for: userID, rejected: token)
        let second = try await perform(method, path: path, body: body, timeout: timeout, token: fresh)
        guard second.1.statusCode == 401 else { return second }
        try await failIfAccountDeleted(second.0)
        await tokenProvider.sessionRejected(for: userID)
        throw AuthError.sessionExpired
    }

    /// `DELETE /api/me/`: 204 when the account and its data are gone. An account the server
    /// already deleted surfaces as `AuthError.accountDeleted`, which callers treat the same way.
    /// An Apple account passes the fresh authorization code the server revokes Apple's tokens
    /// with; without one the request has no body.
    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        var body: Data?
        if let appleAuthorizationCode {
            body = try JSONSerialization.data(withJSONObject: ["apple_authorization_code": appleAuthorizationCode])
        }
        let (_, http) = try await send("DELETE", path: "api/me/", body: body)
        guard http.statusCode == 204 || http.statusCode == 200 else {
            throw APIError.status(http.statusCode)
        }
    }

    // MARK: - Internals

    /// A 401 whose body says the account is gone is not a token problem: no refresh, no retry.
    private func failIfAccountDeleted(_ body: Data) async throws {
        guard Self.detail(in: body) == "Account deleted." else { return }
        await tokenProvider.accountDeleted(for: userID)
        throw AuthError.accountDeleted
    }

    private func perform(
        _ method: String,
        path: String,
        body: Data?,
        timeout: TimeInterval,
        token: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(for: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        do {
            return try await transport.send(request)
        } catch {
            throw APIError.network
        }
    }

    private static func detail(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }
}

// MARK: - Snapshot sync

/// The account's cloud copy of the store, as raw JSON so the bytes match what the app wrote.
nonisolated struct RemoteSnapshot: Sendable, Equatable {
    var version: Int
    var updatedAt: String?
    var data: Data
}

nonisolated struct SnapshotSyncClient: Sendable {
    let api: PlanditAPIClient

    /// `GET /api/me/snapshot/`: the snapshot, or nil on 404.
    func fetch() async throws -> RemoteSnapshot? {
        let (data, http) = try await api.send("GET", path: "api/me/snapshot/")
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? Int,
            let payload = object["data"] as? [String: Any],
            let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        else {
            throw APIError.invalidResponse
        }
        return RemoteSnapshot(version: version, updatedAt: object["updated_at"] as? String, data: payloadData)
    }

    /// `PUT /api/me/snapshot/` with `{"data": <snapshot>}`; returns the new version.
    func push(_ snapshot: Data, timeout: TimeInterval = 30) async throws -> Int {
        var body = Data("{\"data\":".utf8)
        body.append(snapshot)
        body.append(Data("}".utf8))
        let (data, http) = try await api.send("PUT", path: "api/me/snapshot/", body: body, timeout: timeout)
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? Int
        else {
            throw APIError.invalidResponse
        }
        return version
    }
}

// MARK: - Usage events

nonisolated enum UsageEvent: String, Sendable, CaseIterable {
    case planBuilt = "plan_built"
    case linkSaved = "link_saved"
    case placeSaved = "place_saved"
}

/// `POST /api/me/events/`. Fire and forget: a lost event is never surfaced to the person.
nonisolated struct UsageEventClient: Sendable {
    let api: PlanditAPIClient

    func send(_ event: UsageEvent, occurredAt: Date = Date()) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": event.rawValue,
            "occurred_at": ISO8601DateFormatter().string(from: occurredAt),
        ])
        let (_, http) = try await api.send("POST", path: "api/me/events/", body: body)
        guard 200..<300 ~= http.statusCode else { throw APIError.status(http.statusCode) }
    }
}
