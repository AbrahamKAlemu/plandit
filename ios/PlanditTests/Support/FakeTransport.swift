import Foundation
@testable import Plandit

/// Canned HTTP: the handler maps each request to a status and body, every request is recorded.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [URLRequest] = []
    private var delay: Duration = .zero
    private var delayed: @Sendable (URLRequest) -> Bool = { _ in true }

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (handler, delay) = lock.withLock {
            recorded.append(request)
            return (self.handler, delayed(request) ? self.delay : .zero)
        }
        if delay > .zero {
            // Deliberately survives cancellation: the response still arrives, as a real one might.
            try? await Task.sleep(for: delay)
        }
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }

    func respond(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    /// This transport's current handler, to hand to another one.
    var handlerForTests: Handler {
        lock.withLock { handler }
    }

    /// Slows the matching requests down (all of them by default).
    func delayResponses(by delay: Duration, matching: @escaping @Sendable (URLRequest) -> Bool = { _ in true }) {
        lock.withLock {
            self.delay = delay
            self.delayed = matching
        }
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func requests(_ method: String, pathContaining fragment: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == method && ($0.url?.absoluteString.contains(fragment) ?? false) }
    }
}

/// Always has a token; ignores the account binding.
struct FakeTokenProvider: AccessTokenProviding {
    var token = "test-token"

    func accessToken() async throws -> String { token }
    func accessToken(for userID: String, rejected: String?) async throws -> String { token }
    func sessionRejected(for userID: String) async {}
    func accountDeleted(for userID: String) async {}
}

enum TestJSON {
    static let configuration = ProductionAPIConfiguration(
        apiBaseURL: URL(string: "https://api.example")!,
        supabaseURL: URL(string: "https://sb.example")!,
        supabaseAnonKey: "anon-key"
    )

    static func session(access: String = "access", refresh: String = "refresh", expiresIn: Int = 3600, provider: String = "email", name: String? = "Sofia", userID: String = "user-1") -> Data {
        var user: [String: Any] = ["id": userID, "email": "sofia@example.edu", "app_metadata": ["provider": provider]]
        if let name { user["user_metadata"] = ["full_name": name] }
        let object: [String: Any] = [
            "access_token": access, "token_type": "bearer", "expires_in": expiresIn, "refresh_token": refresh, "user": user,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func bareUser(identities: [Any]? = [["id": "user-1"]]) -> Data {
        var object: [String: Any] = ["id": "user-1", "aud": "authenticated", "email": "sofia@example.edu", "confirmation_sent_at": "2026-11-07T15:04:05Z"]
        if let identities { object["identities"] = identities }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func object(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }
}
