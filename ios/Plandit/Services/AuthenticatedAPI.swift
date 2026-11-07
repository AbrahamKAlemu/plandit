import Foundation

nonisolated struct ProductionAPIConfiguration: Sendable {
    let apiBaseURL: URL
    let supabaseURL: URL
    let supabaseAnonKey: String

    static var current: ProductionAPIConfiguration? {
        guard
            let apiBaseURL = configuredURL(named: "PlanditAPIBaseURL"),
            let supabaseURL = configuredURL(named: "PlanditSupabaseURL"),
            let supabaseAnonKey = configuredString(named: "PlanditSupabaseAnonKey")
        else {
            return nil
        }
        return ProductionAPIConfiguration(
            apiBaseURL: apiBaseURL,
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseAnonKey
        )
    }

    private static func configuredURL(named key: String) -> URL? {
        guard
            let value = configuredString(named: key),
            let url = URL(string: value),
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }

    private static func configuredString(named key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

protocol AccessTokenProviding: Sendable {
    /// A valid token for whoever is signed in.
    func accessToken() async throws -> String
    /// A valid token for this account only; throws when someone else is signed in. Passing the
    /// token a server just rejected forces one (coalesced) refresh before answering.
    func accessToken(for userID: String, rejected: String?) async throws -> String
    /// The server rejected a freshly refreshed token: the session is gone, sign the person out.
    func sessionRejected(for userID: String) async
    /// The server says this account no longer exists: drop its data and sign the person out.
    func accountDeleted(for userID: String) async
}

/// One HTTP round trip. URLSession in the app; a canned fake in tests.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated extension URLSession: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
