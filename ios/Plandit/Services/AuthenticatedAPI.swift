import Foundation
import Security

struct ProductionAPIConfiguration: Sendable {
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
    func accessToken() async throws -> String
}

actor SupabaseAnonymousSession: AccessTokenProviding {
    fileprivate struct Session: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
    }

    private struct SessionResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: TimeInterval
    }

    private let configuration: ProductionAPIConfiguration
    private let urlSession: URLSession
    private let keychain = SessionKeychain()
    private var session: Session?

    init(
        configuration: ProductionAPIConfiguration,
        urlSession: URLSession = .shared
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        session = keychain.load()
    }

    func accessToken() async throws -> String {
        if let session, session.expiresAt > Date().addingTimeInterval(60) {
            return session.accessToken
        }
        if let refreshToken = session?.refreshToken {
            do {
                return try await updateSession(
                    path: "/auth/v1/token?grant_type=refresh_token",
                    body: ["refresh_token": refreshToken],
                    isRefresh: true
                ).accessToken
            } catch AuthenticatedAPIError.invalidRefreshToken {
                keychain.remove()
                session = nil
            }
        }
        return try await updateSession(path: "/auth/v1/signup", body: [:]).accessToken
    }

    private func updateSession(
        path: String,
        body: [String: String],
        isRefresh: Bool = false
    ) async throws -> Session {
        guard let endpoint = URL(string: path, relativeTo: configuration.supabaseURL) else {
            throw AuthenticatedAPIError.invalidConfiguration
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthenticatedAPIError.signInFailed
        }
        if isRefresh, [400, 401].contains(http.statusCode) {
            throw AuthenticatedAPIError.invalidRefreshToken
        }
        guard 200..<300 ~= http.statusCode else {
            throw AuthenticatedAPIError.signInFailed
        }
        let payload = try JSONDecoder.supabase.decode(SessionResponse.self, from: data)
        let updated = Session(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date().addingTimeInterval(payload.expiresIn)
        )
        try keychain.save(updated)
        session = updated
        return updated
    }
}

/// Nonisolated: used from the SupabaseAnonymousSession actor, never from the main actor.
nonisolated private struct SessionKeychain: Sendable {
    private let service = "com.plandit.app.supabase"
    private let account = "anonymous-session"

    func load() -> SupabaseAnonymousSession.Session? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(SupabaseAnonymousSession.Session.self, from: data)
    }

    func save(_ session: SupabaseAnonymousSession.Session) throws {
        let data = try JSONEncoder().encode(session)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw AuthenticatedAPIError.sessionStorageFailed
            }
        } else if status != errSecSuccess {
            throw AuthenticatedAPIError.sessionStorageFailed
        }
    }

    func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private extension JSONDecoder {
    nonisolated static var supabase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

enum AuthenticatedAPIError: LocalizedError {
    case invalidConfiguration
    case invalidRefreshToken
    case signInFailed
    case sessionStorageFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Plandit's service is not configured."
        case .invalidRefreshToken:
            "Plandit's session expired."
        case .signInFailed:
            "Plandit couldn't start a secure session. Try again."
        case .sessionStorageFailed:
            "Plandit couldn't securely save this session."
        }
    }
}
