import Foundation
import Observation

/// Drives the auth gate: who is signed in, what the sign-in screens are doing, and sign-out/delete.
@Observable
@MainActor
final class AccountModel {
    enum State: Equatable {
        case loading
        case signedOut
        case awaitingConfirmation(email: String)
        case signedIn(AuthUser)
    }

    private(set) var state: State
    private(set) var isBusy = false
    /// Inline error for whichever screen is showing; cleared when a new action starts.
    var errorMessage: String?
    /// Set after a successful resend so the screen can say so.
    private(set) var didResendConfirmation = false
    /// Apple shares the person's name only on the first authorization; it seeds the new profile.
    private(set) var pendingProfileName: String?
    /// `-skipAuth` (debug builds only): a fixed local account, no sync, no events.
    let isLocalTestAccount: Bool

    @ObservationIgnored private let apiBaseURL: URL?
    @ObservationIgnored private let client: SupabaseAuthClient?
    @ObservationIgnored private let transport: any HTTPTransport
    /// Gets a fresh Apple authorization code before an Apple account is deleted.
    @ObservationIgnored private let appleReauthorizer: any AppleReauthorizing
    /// Runs before the session is dropped: the final sync push.
    @ObservationIgnored var beforeSignOut: (() async -> Void)?
    /// Runs once the server confirmed the account is gone, with the user id.
    @ObservationIgnored var onAccountDeleted: ((String) -> Void)?

    init(
        client: SupabaseAuthClient?,
        apiBaseURL: URL?,
        transport: any HTTPTransport = URLSession.shared,
        appleReauthorizer: any AppleReauthorizing = AppleReauthorizer(),
        state: State = .loading,
        isLocalTestAccount: Bool = false
    ) {
        self.client = client
        self.apiBaseURL = apiBaseURL
        self.transport = transport
        self.appleReauthorizer = appleReauthorizer
        self.state = state
        self.isLocalTestAccount = isLocalTestAccount
    }

    static func live() -> AccountModel {
        guard let configuration = ProductionAPIConfiguration.current, let client = SupabaseAuthClient.shared else {
            return AccountModel(client: nil, apiBaseURL: nil)
        }
        return AccountModel(client: client, apiBaseURL: configuration.apiBaseURL)
    }

    static let localTestUser = AuthUser(id: "local-test-account", email: "test@plandit.local", fullName: nil, provider: "email")

    static func localTest() -> AccountModel {
        AccountModel(client: nil, apiBaseURL: nil, state: .signedIn(localTestUser), isLocalTestAccount: true)
    }

    /// The API client bound to one account: its requests fail rather than run as whoever is
    /// signed in later.
    func api(for userID: String) -> PlanditAPIClient? {
        guard let apiBaseURL, let client else { return nil }
        return PlanditAPIClient(baseURL: apiBaseURL, userID: userID, tokenProvider: client, transport: transport)
    }

    var currentUser: AuthUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    /// Reads the stored session once at launch.
    func start() async {
        guard case .loading = state else { return }
        guard let client else {
            state = .signedOut
            return
        }
        await client.setSignedOutHandler { [weak self] in
            Task { @MainActor in self?.sessionWasRevoked() }
        }
        await client.setAccountDeletedHandler { [weak self] userID in
            Task { @MainActor in await self?.accountWasDeleted(userID) }
        }
        if let user = await client.currentUser {
            state = .signedIn(user)
        } else {
            state = .signedOut
        }
    }

    // MARK: - Sign up / sign in

    func signUp(email: String, password: String, name: String) async {
        guard let client else { return notConfigured() }
        await perform(email: email) {
            switch try await client.signUp(email: email, password: password, name: name) {
            case .signedIn(let session):
                pendingProfileName = name
                state = .signedIn(session.user)
            case .confirmationRequired(let email):
                pendingProfileName = name
                didResendConfirmation = false
                state = .awaitingConfirmation(email: email)
            }
        }
    }

    func signIn(email: String, password: String) async {
        guard let client else { return notConfigured() }
        await perform(email: email) {
            state = .signedIn(try await client.signIn(email: email, password: password))
        }
    }

    func signInWithApple(idToken: String, rawNonce: String, fullName: String?) async {
        guard let client else { return notConfigured() }
        await perform(email: nil) {
            let user = try await client.signInWithApple(idToken: idToken, rawNonce: rawNonce)
            pendingProfileName = fullName
            state = .signedIn(user)
        }
    }

    func resendConfirmation() async {
        guard case .awaitingConfirmation(let email) = state else { return }
        guard let client else { return notConfigured() }
        didResendConfirmation = false
        await perform(email: email) {
            try await client.resendConfirmation(email: email)
            didResendConfirmation = true
        }
    }

    /// "Sign in" on the check-your-email screen: back to the gate with the form on Sign in.
    func showSignIn() {
        errorMessage = nil
        pendingProfileName = nil
        didResendConfirmation = false
        state = .signedOut
    }

    // MARK: - Sign out / delete

    func signOut() async {
        isBusy = true
        defer { isBusy = false }
        await beforeSignOut?()
        await client?.signOut()
        finishSignOut()
    }

    /// `DELETE /api/me/`. An Apple account first re-authorizes with Apple so the server can revoke
    /// its tokens: dismissing that sheet deletes nothing and shows nothing. If the sheet fails for
    /// any other reason the account is deleted without a code (in-app deletion must always work;
    /// revocation is best effort). On 204 the local copy goes too; on any failure of the request
    /// the person stays signed in.
    func deleteAccount() async {
        guard !isBusy, case .signedIn(let user) = state else { return }
        guard let api = api(for: user.id) else { return notConfigured() }
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        var appleAuthorizationCode: String?
        if await usesSignInWithApple(user) {
            do {
                appleAuthorizationCode = try await appleReauthorizer.authorizationCode()
            } catch AppleReauthorizationError.canceled {
                return
            } catch {
                appleAuthorizationCode = nil  // delete anyway; the server logs that it had no code
            }
        }
        do {
            try await api.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
            await accountWasDeleted(user.id)
        } catch AuthError.accountDeleted {
            // Already gone on the server: the outcome the person asked for.
            await accountWasDeleted(user.id)
        } catch let error as AuthError {
            errorMessage = AuthCopy.message(for: error, email: user.email)
        } catch APIError.network {
            errorMessage = AuthCopy.network
        } catch {
            errorMessage = AuthCopy.deleteFailed
        }
    }

    // MARK: - Internals

    private func perform(email: String?, _ work: () async throws -> Void) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
        } catch let error as AuthError {
            errorMessage = AuthCopy.message(for: error, email: email)
        } catch {
            errorMessage = AuthCopy.generic
        }
    }

    private func notConfigured() {
        errorMessage = AuthCopy.notConfigured
    }

    /// `state` is set at launch or sign-in; a session refreshed since then can know about a linked
    /// Apple identity that a session stored by an older build didn't record.
    private func usesSignInWithApple(_ user: AuthUser) async -> Bool {
        if user.signedInWithApple { return true }
        guard let stored = await client?.currentUser, stored.id == user.id else { return false }
        return stored.signedInWithApple
    }

    private func finishSignOut() {
        pendingProfileName = nil
        errorMessage = nil
        didResendConfirmation = false
        state = .signedOut
    }

    private func sessionWasRevoked() {
        guard case .signedIn = state else { return }
        finishSignOut()
    }

    /// The server no longer has this account (a delete, here or from another device): drop the
    /// local copy, the session, and show the gate. Safe to call more than once.
    private func accountWasDeleted(_ userID: String) async {
        guard case .signedIn(let user) = state, user.id == userID else { return }
        onAccountDeleted?(userID)
        await client?.clearSession()
        finishSignOut()
    }
}
