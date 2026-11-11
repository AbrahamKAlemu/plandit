import Foundation
import Security

/// Who is signed in, as Supabase reports it.
nonisolated struct AuthUser: Codable, Sendable, Equatable {
    var id: String
    var email: String?
    var fullName: String?
    /// `app_metadata.provider`: the provider the account was created with, "email" or "apple".
    var provider: String?
    /// `app_metadata.providers`: every linked provider, e.g. ["email", "apple"] for an email
    /// account that later used Sign in with Apple. Nil for sessions saved by builds before 1.0's
    /// Apple token revocation (the Keychain JSON has no such key) and decoded as before.
    var providers: [String]? = nil

    /// True when Apple is linked at all, so deleting the account revokes Apple's tokens.
    var signedInWithApple: Bool { provider == "apple" || providers?.contains("apple") == true }
}

nonisolated struct AuthSession: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var user: AuthUser

    /// Still usable without a refresh: more than `margin` seconds left.
    func isValid(at date: Date, margin: TimeInterval = 60) -> Bool {
        expiresAt > date.addingTimeInterval(margin)
    }
}

nonisolated enum SignUpOutcome: Sendable, Equatable {
    case signedIn(AuthSession)
    /// The project requires email confirmation; the person taps the emailed link, then signs in.
    case confirmationRequired(email: String)
}

nonisolated enum AuthError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredentials
    case emailNotConfirmed
    case userAlreadyExists
    case weakPassword
    case invalidEmail
    case emailRateLimited
    case network
    /// The refresh token was rejected; the session was cleared.
    case sessionExpired
    /// A request bound to one account was made while another one is signed in.
    case accountMismatch
    /// The API answered that the account no longer exists.
    case accountDeleted
    case server(status: Int, message: String?)
    case invalidResponse
}

// MARK: - Response decoding

/// Supabase Auth (GoTrue) payloads, decoded leniently: the shape differs between a session and a
/// bare user, and between old and new error formats.
nonisolated enum SupabaseAuthResponse {
    static func decodeSession(_ data: Data, now: Date) throws -> AuthSession {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }
        return try session(from: object, now: now)
    }

    /// `POST /auth/v1/signup` returns a session when confirmation is off, otherwise the new user alone
    /// (either top-level or under `user` with `session: null`). An existing email comes back as an
    /// obfuscated user with no identities.
    static func decodeSignUp(_ data: Data, email: String, now: Date) throws -> SignUpOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }
        if object["access_token"] is String {
            return .signedIn(try session(from: object, now: now))
        }
        let userObject = (object["user"] as? [String: Any]) ?? object
        guard user(from: userObject) != nil else { throw AuthError.invalidResponse }
        if let identities = userObject["identities"] as? [Any], identities.isEmpty {
            throw AuthError.userAlreadyExists
        }
        let confirmedEmail = (userObject["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .confirmationRequired(email: confirmedEmail ?? email)
    }

    /// Maps `{"error_code": ..., "msg": ...}` and the older `{"error": ..., "error_description": ...}`.
    static func error(status: Int, data: Data) -> AuthError {
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = (object["error_code"] as? String) ?? (object["error"] as? String)
        let message = (object["msg"] as? String)
            ?? (object["error_description"] as? String)
            ?? (object["message"] as? String)
        let lowered = message?.lowercased() ?? ""

        switch code {
        case "invalid_credentials": return .invalidCredentials
        case "email_not_confirmed": return .emailNotConfirmed
        case "user_already_exists", "email_exists": return .userAlreadyExists
        case "weak_password": return .weakPassword
        case "email_address_invalid": return .invalidEmail
        case "over_email_send_rate_limit", "over_request_rate_limit": return .emailRateLimited
        case "validation_failed" where lowered.contains("email"): return .invalidEmail
        default: break
        }
        if lowered.contains("not confirmed") { return .emailNotConfirmed }
        if lowered.contains("invalid login") { return .invalidCredentials }
        if lowered.contains("already registered") || lowered.contains("already exists") { return .userAlreadyExists }
        if lowered.contains("password should be") || lowered.contains("password is too") { return .weakPassword }
        if lowered.contains("validate email") || lowered.contains("invalid email") { return .invalidEmail }
        if lowered.contains("rate limit") || status == 429 { return .emailRateLimited }
        if code == "invalid_grant" { return .invalidCredentials }
        return .server(status: status, message: message)
    }

    private static func session(from object: [String: Any], now: Date) throws -> AuthSession {
        guard
            let accessToken = object["access_token"] as? String,
            let refreshToken = object["refresh_token"] as? String,
            let userObject = object["user"] as? [String: Any],
            let user = user(from: userObject)
        else {
            throw AuthError.invalidResponse
        }
        let expiresIn = (object["expires_in"] as? Double) ?? 3600
        return AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            user: user
        )
    }

    private static func user(from object: [String: Any]) -> AuthUser? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let metadata = object["user_metadata"] as? [String: Any]
        let app = object["app_metadata"] as? [String: Any]
        let name = ((metadata?["full_name"] as? String) ?? (metadata?["name"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (object["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AuthUser(
            id: id,
            email: email,
            fullName: name.flatMap { $0.isEmpty ? nil : $0 },
            provider: app?["provider"] as? String,
            providers: app?["providers"] as? [String]
        )
    }
}

// MARK: - Session storage

nonisolated protocol AuthSessionStore: Sendable {
    func load() -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear()
}

/// Generic-password item, available after first unlock, never migrated to another device.
nonisolated struct KeychainAuthSessionStore: AuthSessionStore {
    private static let service = "com.plandit.app.supabase"
    private static let account = "auth-session"
    /// The pre-accounts anonymous session. Deleted once; anonymous sign-ins are no longer used.
    private static let legacyAccount = "anonymous-session"

    struct SaveError: Error {}

    func load() -> AuthSession? {
        var query = Self.query(account: Self.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let base = Self.query(account: Self.account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw SaveError() }
        } else if status != errSecSuccess {
            throw SaveError()
        }
    }

    func clear() {
        SecItemDelete(Self.query(account: Self.account) as CFDictionary)
    }

    static func removeLegacyAnonymousSession() {
        SecItemDelete(query(account: legacyAccount) as CFDictionary)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// For tests and the `-skipAuth` build: nothing touches the Keychain.
nonisolated final class InMemoryAuthSessionStore: AuthSessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    init(session: AuthSession? = nil) {
        self.session = session
    }

    func load() -> AuthSession? {
        lock.withLock { session }
    }

    func save(_ session: AuthSession) throws {
        lock.withLock { self.session = session }
    }

    func clear() {
        lock.withLock { session = nil }
    }
}

// MARK: - Client

/// Email, password and Sign in with Apple against Supabase Auth, with one stored session.
/// Refreshes coalesce into a single in-flight request: Supabase rotates refresh tokens and
/// revokes the family when one is reused.
actor SupabaseAuthClient: AccessTokenProviding {
    /// Built from the Info.plist configuration; nil when the build has none.
    static let shared: SupabaseAuthClient? = ProductionAPIConfiguration.current.map {
        SupabaseAuthClient(configuration: $0)
    }

    private let configuration: ProductionAPIConfiguration
    private let transport: any HTTPTransport
    private let sessionStore: any AuthSessionStore
    private let now: @Sendable () -> Date
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?
    private var signedOutHandler: (@Sendable () -> Void)?
    private var accountDeletedHandler: (@Sendable (String) -> Void)?

    init(
        configuration: ProductionAPIConfiguration,
        transport: any HTTPTransport = URLSession.shared,
        sessionStore: any AuthSessionStore = KeychainAuthSessionStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sessionStore = sessionStore
        self.now = now
        session = sessionStore.load()
        KeychainAuthSessionStore.removeLegacyAnonymousSession()
    }

    var currentUser: AuthUser? { session?.user }

    /// Called (off the main actor) when a refresh is rejected and the session has been cleared.
    func setSignedOutHandler(_ handler: @escaping @Sendable () -> Void) {
        signedOutHandler = handler
    }

    /// Called (off the main actor) when the API reports the signed-in account as deleted. The
    /// session is left for the handler to clear once the local data is gone.
    func setAccountDeletedHandler(_ handler: @escaping @Sendable (String) -> Void) {
        accountDeletedHandler = handler
    }

    func signUp(email: String, password: String, name: String?) async throws -> SignUpOutcome {
        var body: [String: Any] = ["email": email, "password": password]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            body["data"] = ["full_name": name]
        }
        let (data, http) = try await post(path: "/auth/v1/signup", body: body, bearer: nil)
        try throwIfFailed(http, data)
        let outcome = try SupabaseAuthResponse.decodeSignUp(data, email: email, now: now())
        if case .signedIn(let session) = outcome { adopt(session) }
        return outcome
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        let (data, http) = try await post(
            path: "/auth/v1/token?grant_type=password",
            body: ["email": email, "password": password],
            bearer: nil
        )
        try throwIfFailed(http, data)
        let session = try SupabaseAuthResponse.decodeSession(data, now: now())
        adopt(session)
        return session.user
    }

    func signInWithApple(idToken: String, rawNonce: String) async throws -> AuthUser {
        let (data, http) = try await post(
            path: "/auth/v1/token?grant_type=id_token",
            body: ["provider": "apple", "id_token": idToken, "nonce": rawNonce],
            bearer: nil
        )
        try throwIfFailed(http, data)
        let session = try SupabaseAuthResponse.decodeSession(data, now: now())
        adopt(session)
        return session.user
    }

    func resendConfirmation(email: String) async throws {
        let (data, http) = try await post(
            path: "/auth/v1/resend",
            body: ["type": "signup", "email": email],
            bearer: nil
        )
        try throwIfFailed(http, data)
    }

    /// Best-effort server logout, then always forget the session locally.
    func signOut() async {
        if let session {
            _ = try? await post(path: "/auth/v1/logout", body: [:], bearer: session.accessToken)
        }
        clearSession()
    }

    func clearSession() {
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        sessionStore.clear()
    }

    func accessToken() async throws -> String {
        if let session, session.isValid(at: now()) {
            return session.accessToken
        }
        return try await refreshedToken()
    }

    func accessToken(for userID: String, rejected: String?) async throws -> String {
        guard let session else { throw AuthError.sessionExpired }
        guard session.user.id == userID else { throw AuthError.accountMismatch }
        if let rejected, session.accessToken == rejected {
            // Nobody refreshed since the server said no: do it now, once.
            return try await refreshedToken()
        }
        return try await accessToken()
    }

    func sessionRejected(for userID: String) {
        guard let session, session.user.id == userID else { return }
        clearSession()
        signedOutHandler?()
    }

    func accountDeleted(for userID: String) {
        guard let session, session.user.id == userID else { return }
        accountDeletedHandler?(userID)
    }

    // MARK: - Internals

    /// One refresh at a time; concurrent callers wait for the same request.
    private func refreshedToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        guard let refreshToken = session?.refreshToken else { throw AuthError.sessionExpired }
        let task = Task { try await self.refresh(refreshToken) }
        refreshTask = task
        defer { if refreshTask == task { refreshTask = nil } }
        return try await task.value.accessToken
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        let (data, http) = try await post(
            path: "/auth/v1/token?grant_type=refresh_token",
            body: ["refresh_token": refreshToken],
            bearer: nil
        )
        // Signed out or switched accounts while the request was out: the answer, good or bad,
        // is about a session nobody holds any more.
        let stillCurrent = self.session?.refreshToken == refreshToken
        if [400, 401].contains(http.statusCode) {
            if stillCurrent {
                clearSession()
                signedOutHandler?()
            }
            throw AuthError.sessionExpired
        }
        try throwIfFailed(http, data)
        let session = try SupabaseAuthResponse.decodeSession(data, now: now())
        guard stillCurrent else { throw AuthError.sessionExpired }
        adopt(session)
        return session
    }

    private func adopt(_ session: AuthSession) {
        self.session = session
        // A Keychain write can fail in odd environments; the in-memory session still carries this run.
        try? sessionStore.save(session)
    }

    private func throwIfFailed(_ http: HTTPURLResponse, _ data: Data) throws {
        guard 200..<300 ~= http.statusCode else {
            throw SupabaseAuthResponse.error(status: http.statusCode, data: data)
        }
    }

    private func post(path: String, body: [String: Any], bearer: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: configuration.supabaseURL)?.absoluteURL else {
            throw AuthError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer ?? configuration.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await transport.send(request)
        } catch {
            throw AuthError.network
        }
    }
}
