import XCTest
@testable import Plandit

/// Deleting an account signed in with Apple: a fresh authorization code goes with the request so
/// the server can revoke Apple's tokens. Cancel deletes nothing quietly; a failure deletes without a
/// code (revocation is best effort, deletion must always work); email accounts never see the sheet.
@MainActor final class AppleReauthorizationTests: XCTestCase {
    private final class FakeAppleReauthorizer: AppleReauthorizing {
        enum Outcome {
            case code(String)
            case canceled
            case failed
        }

        var outcome: Outcome
        private(set) var calls = 0

        init(_ outcome: Outcome) {
            self.outcome = outcome
        }

        func authorizationCode() async throws -> String {
            calls += 1
            switch outcome {
            case .code(let code): return code
            case .canceled: throw AppleReauthorizationError.canceled
            case .failed: throw AppleReauthorizationError.failed
            }
        }
    }

    /// Holds the sheet up until the test answers it. A second request while it is up fails, as the
    /// system sheet does.
    @MainActor private final class SuspendingAppleReauthorizer: AppleReauthorizing {
        private(set) var calls = 0
        private var pending: CheckedContinuation<String, Error>?

        var isShowingSheet: Bool { pending != nil }

        func authorizationCode() async throws -> String {
            calls += 1
            guard pending == nil else { throw AppleReauthorizationError.failed }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func answer(throwing error: Error) {
            pending?.resume(throwing: error)
            pending = nil
        }
    }

    private let appleUser = AuthUser(id: "user-1", email: nil, fullName: nil, provider: "apple")
    private let emailUser = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")

    /// The app's wiring: a signed-in client with a valid session, the fake sheet, one transport.
    private func signedInAccount(
        _ user: AuthUser,
        reauthorizer: any AppleReauthorizing,
        transport: FakeTransport
    ) async -> (AccountModel, InMemoryAuthSessionStore) {
        let session = AuthSession(accessToken: "valid", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600), user: user)
        let store = InMemoryAuthSessionStore(session: session)
        let client = SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: store)
        let account = AccountModel(
            client: client, apiBaseURL: TestJSON.configuration.apiBaseURL, transport: transport, appleReauthorizer: reauthorizer
        )
        await account.start()
        XCTAssertEqual(account.state, .signedIn(user))
        return (account, store)
    }

    /// `state` as set at launch from `launchUser`, while the client's session holds `storedUser`, as
    /// a token refresh since launch would have saved it.
    private func launchedAccount(
        _ launchUser: AuthUser,
        storedSessionUser storedUser: AuthUser,
        reauthorizer: FakeAppleReauthorizer,
        transport: FakeTransport
    ) -> AccountModel {
        let session = AuthSession(accessToken: "valid", refreshToken: "refresh-2", expiresAt: Date().addingTimeInterval(3600), user: storedUser)
        let client = SupabaseAuthClient(
            configuration: TestJSON.configuration, transport: transport, sessionStore: InMemoryAuthSessionStore(session: session)
        )
        return AccountModel(
            client: client, apiBaseURL: TestJSON.configuration.apiBaseURL, transport: transport, appleReauthorizer: reauthorizer,
            state: .signedIn(launchUser)
        )
    }

    private func deleteTransport() -> FakeTransport {
        FakeTransport { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/me/")
            return (204, Data())
        }
    }

    private func body(of request: URLRequest) -> [String: String]? {
        request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    }

    func testAnAppleAccountSendsTheFreshAuthorizationCode() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.code("fake-apple-code-for-tests"))
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(body(of: deletes[0]), ["apple_authorization_code": "fake-apple-code-for-tests"])
        XCTAssertEqual(deletes[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.isBusy)
        XCTAssertNil(store.load())
    }

    func testCancelingTheAppleSheetDeletesNothingAndShowsNothing() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.canceled)
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        XCTAssertTrue(transport.requests.isEmpty, "nothing sent")
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.isBusy)
        XCTAssertNotNil(store.load())
    }

    func testAnAppleSheetFailureStillDeletesTheAccountWithoutACode() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.failed)
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNil(deletes[0].httpBody)
        XCTAssertNil(deletes[0].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage, "the sheet failure itself shows nothing")
        XCTAssertFalse(account.isBusy)
        XCTAssertNil(store.load())
    }

    func testAServerFailureAfterAFailedAppleSheetShowsDeleteFailed() async throws {
        let transport = FakeTransport { _ in (502, TestJSON.object(["detail": "Could not delete the sign-in account."])) }
        let reauthorizer = FakeAppleReauthorizer(.failed)
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNil(deletes[0].httpBody)
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertEqual(account.errorMessage, AuthCopy.deleteFailed)
        XCTAssertFalse(account.isBusy)
        XCTAssertNotNil(store.load())
    }

    func testAnEmailAccountWithAppleLinkedIsAskedForACode() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.code("fake-apple-code-for-tests"))
        let linked = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email", providers: ["email", "apple"])
        let (account, _) = await signedInAccount(linked, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(body(of: deletes[0]), ["apple_authorization_code": "fake-apple-code-for-tests"])
        XCTAssertEqual(account.state, .signedOut)
    }

    func testAnEmailAccountIsNotAskedAndSendsNoBody() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.code("never used"))
        let (account, store) = await signedInAccount(emailUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 0)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertNil(deletes[0].httpBody)
        XCTAssertNil(deletes[0].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage)
        XCTAssertNil(store.load())
    }

    func testAServerFailureAfterTheAppleSheetKeepsThePersonSignedIn() async throws {
        let transport = FakeTransport { _ in (502, TestJSON.object(["detail": "Could not delete the sign-in account."])) }
        let reauthorizer = FakeAppleReauthorizer(.code("fake-apple-code-for-tests"))
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/me/").count, 1)
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertEqual(account.errorMessage, AuthCopy.deleteFailed)
        XCTAssertNotNil(store.load())
    }

    /// A session stored by an older build has no `providers`; a refresh since launch recorded the
    /// linked Apple identity in the client's session but not in `state`.
    func testALinkedAppleIdentityFromTheRefreshedSessionIsAskedForACode() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.code("fake-apple-code-for-tests"))
        let refreshed = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email", providers: ["email", "apple"])
        let account = launchedAccount(emailUser, storedSessionUser: refreshed, reauthorizer: reauthorizer, transport: transport)
        XCTAssertNil(emailUser.providers)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(body(of: deletes[0]), ["apple_authorization_code": "fake-apple-code-for-tests"])
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage)
    }

    /// The client's session is someone else's: its Apple identity says nothing about this account.
    /// (No DELETE goes out either: the client won't hand this account a token for another one.)
    func testAnotherAccountsStoredSessionDoesNotShowTheAppleSheet() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.code("never used"))
        let other = AuthUser(id: "user-2", email: nil, fullName: nil, provider: "apple", providers: ["apple"])
        let account = launchedAccount(emailUser, storedSessionUser: other, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 0)
        XCTAssertTrue(transport.requests.isEmpty, "nothing sent")
        XCTAssertEqual(account.state, .signedIn(emailUser))
        XCTAssertEqual(account.errorMessage, AuthCopy.message(for: .accountMismatch, email: emailUser.email))
        XCTAssertFalse(account.isBusy)
    }

    func testASecondDeleteWhileTheAppleSheetIsUpIsIgnored() async throws {
        let transport = deleteTransport()
        let reauthorizer = SuspendingAppleReauthorizer()
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        let first = Task { await account.deleteAccount() }
        for _ in 0..<1_000 where !reauthorizer.isShowingSheet {
            await Task.yield()
        }
        XCTAssertTrue(reauthorizer.isShowingSheet)
        XCTAssertTrue(account.isBusy)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1, "the second delete never asked for the sheet")
        XCTAssertTrue(transport.requests.isEmpty, "the second delete sent nothing")
        XCTAssertTrue(account.isBusy, "the first delete is still running")

        reauthorizer.answer(throwing: AppleReauthorizationError.canceled)
        await first.value

        XCTAssertEqual(reauthorizer.calls, 1)
        XCTAssertTrue(transport.requests.isEmpty, "canceling the visible sheet deleted nothing")
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertNil(account.errorMessage)
        XCTAssertFalse(account.isBusy)
        XCTAssertNotNil(store.load())
    }

    // MARK: - Which accounts count as Apple

    private func decodedUser(appMetadata: [String: Any]) throws -> AuthUser {
        let object: [String: Any] = [
            "access_token": "access", "token_type": "bearer", "expires_in": 3600, "refresh_token": "refresh",
            "user": ["id": "user-1", "email": "sofia@example.edu", "app_metadata": appMetadata],
        ]
        return try SupabaseAuthResponse.decodeSession(TestJSON.object(object), now: Date()).user
    }

    func testAnEmailAccountThatLinkedAppleCountsAsApple() throws {
        let user = try decodedUser(appMetadata: ["provider": "email", "providers": ["email", "apple"]])
        XCTAssertEqual(user.provider, "email")
        XCTAssertEqual(user.providers, ["email", "apple"])
        XCTAssertTrue(user.signedInWithApple)
    }

    func testAnAppleAccountCountsAsApple() throws {
        XCTAssertTrue(try decodedUser(appMetadata: ["provider": "apple", "providers": ["apple"]]).signedInWithApple)
        XCTAssertTrue(try decodedUser(appMetadata: ["provider": "apple"]).signedInWithApple)
    }

    func testAnEmailOnlyAccountDoesNotCountAsApple() throws {
        XCTAssertFalse(try decodedUser(appMetadata: ["provider": "email", "providers": ["email"]]).signedInWithApple)
        XCTAssertFalse(try decodedUser(appMetadata: ["provider": "email"]).signedInWithApple)
        XCTAssertFalse(try decodedUser(appMetadata: [:]).signedInWithApple)
    }

    /// A session saved in the Keychain by an earlier build has no `providers` key and must still
    /// load, with the same answer as before.
    func testALegacyStoredSessionWithoutProvidersStillDecodes() throws {
        func legacy(provider: String) throws -> AuthSession {
            let json = """
            {"accessToken":"access","refreshToken":"refresh","expiresAt":"2026-11-10T12:00:00Z",\
            "user":{"id":"user-1","email":"sofia@example.edu","fullName":"Sofia","provider":"\(provider)"}}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AuthSession.self, from: Data(json.utf8))
        }
        let apple = try legacy(provider: "apple")
        XCTAssertNil(apple.user.providers)
        XCTAssertTrue(apple.user.signedInWithApple)
        let email = try legacy(provider: "email")
        XCTAssertEqual(email.user, AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email"))
        XCTAssertFalse(email.user.signedInWithApple)

        // And a session saved by this build round-trips with its providers.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let linked = AuthSession(
            accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            user: AuthUser(id: "user-1", email: nil, fullName: nil, provider: "email", providers: ["email", "apple"])
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(AuthSession.self, from: encoder.encode(linked)), linked)
    }

    // MARK: - PlanditAPIClient

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }

    func testDeleteAccountSendsTheCodeAsJSONOnlyWhenThereIsOne() async throws {
        let transport = FakeTransport { _ in (204, Data()) }

        try await api(transport).deleteAccount(appleAuthorizationCode: "fake-apple-code-for-tests")
        try await api(transport).deleteAccount(appleAuthorizationCode: nil)
        try await api(transport).deleteAccount()

        let requests = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(body(of: requests[0]), ["apple_authorization_code": "fake-apple-code-for-tests"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        for request in requests.dropFirst() {
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        }
    }
}
