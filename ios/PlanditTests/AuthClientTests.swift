import XCTest
@testable import Plandit

@MainActor final class AuthClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Response decoding

    func testSignUpWithConfirmationOffDecodesASession() throws {
        let outcome = try SupabaseAuthResponse.decodeSignUp(TestJSON.session(), email: "sofia@example.edu", now: now)
        guard case .signedIn(let session) = outcome else { return XCTFail("expected a session, got \(outcome)") }
        XCTAssertEqual(session.accessToken, "access")
        XCTAssertEqual(session.refreshToken, "refresh")
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(session.user, AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email"))
    }

    func testSignUpWithConfirmationOnReturnsConfirmationRequired() throws {
        XCTAssertEqual(
            try SupabaseAuthResponse.decodeSignUp(TestJSON.bareUser(), email: "typed@example.edu", now: now),
            .confirmationRequired(email: "sofia@example.edu")
        )
        let nested = TestJSON.object(["user": ["id": "user-1", "email": "sofia@example.edu"], "session": NSNull()])
        XCTAssertEqual(
            try SupabaseAuthResponse.decodeSignUp(nested, email: "typed@example.edu", now: now),
            .confirmationRequired(email: "sofia@example.edu")
        )
    }

    func testSignUpForAnExistingEmailIsReportedAsAlreadyExists() {
        XCTAssertThrowsError(try SupabaseAuthResponse.decodeSignUp(TestJSON.bareUser(identities: []), email: "a@b.co", now: now)) { error in
            XCTAssertEqual(error as? AuthError, .userAlreadyExists)
        }
    }

    func testGarbageIsAnInvalidResponse() {
        XCTAssertThrowsError(try SupabaseAuthResponse.decodeSession(Data("nope".utf8), now: now)) { error in
            XCTAssertEqual(error as? AuthError, .invalidResponse)
        }
    }

    func testErrorCodesMapToTypedErrors() {
        func mapped(_ status: Int, _ object: [String: Any]) -> AuthError {
            SupabaseAuthResponse.error(status: status, data: TestJSON.object(object))
        }
        XCTAssertEqual(mapped(400, ["code": 400, "error_code": "invalid_credentials", "msg": "Invalid login credentials"]), .invalidCredentials)
        XCTAssertEqual(mapped(400, ["error_code": "email_not_confirmed", "msg": "Email not confirmed"]), .emailNotConfirmed)
        XCTAssertEqual(mapped(422, ["error_code": "user_already_exists", "msg": "User already registered"]), .userAlreadyExists)
        XCTAssertEqual(mapped(422, ["error_code": "weak_password", "msg": "Password should be at least 8 characters."]), .weakPassword)
        XCTAssertEqual(mapped(400, ["error_code": "email_address_invalid", "msg": "Email address is invalid"]), .invalidEmail)
        XCTAssertEqual(mapped(429, ["error_code": "over_email_send_rate_limit", "msg": "For security purposes, you can only request this after 60 seconds."]), .emailRateLimited)
        // Older GoTrue format.
        XCTAssertEqual(mapped(400, ["error": "invalid_grant", "error_description": "Invalid login credentials"]), .invalidCredentials)
        XCTAssertEqual(mapped(400, ["error": "invalid_grant", "error_description": "Email not confirmed"]), .emailNotConfirmed)
        XCTAssertEqual(mapped(500, ["msg": "Database error"]), .server(status: 500, message: "Database error"))
        XCTAssertEqual(mapped(502, [:]), .server(status: 502, message: nil))
    }

    // MARK: - Nonce

    func testNonceHashIsSHA256Hex() {
        XCTAssertEqual(AppleNonce.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(AppleNonce.sha256Hex("").count, 64)
    }

    func testRandomNonceIsLongUrlSafeAndDifferentEachTime() {
        let a = AppleNonce.random()
        let b = AppleNonce.random()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        XCTAssertTrue(a.unicodeScalars.allSatisfy(allowed.contains))
    }

    // MARK: - Client

    private func makeClient(
        session: AuthSession?,
        transport: FakeTransport,
        now: Date? = nil
    ) -> (SupabaseAuthClient, InMemoryAuthSessionStore) {
        let store = InMemoryAuthSessionStore(session: session)
        let client = SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: store, now: { now ?? Date() })
        return (client, store)
    }

    private var staleSession: AuthSession {
        AuthSession(
            accessToken: "stale",
            refreshToken: "refresh-1",
            expiresAt: Date().addingTimeInterval(30), // inside the 60 s margin
            user: AuthUser(id: "user-1", email: "sofia@example.edu", fullName: nil, provider: "email")
        )
    }

    func testFreshTokenIsReturnedWithoutARequest() async throws {
        let transport = FakeTransport { _ in (500, Data()) }
        let fresh = AuthSession(accessToken: "fresh", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), user: staleSession.user)
        let (client, _) = makeClient(session: fresh, transport: transport)
        let token = try await client.accessToken()
        XCTAssertEqual(token, "fresh")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testConcurrentCallsShareOneRefresh() async throws {
        let transport = FakeTransport { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/auth/v1/token?grant_type=refresh_token"))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["refresh_token"], "refresh-1")
            return (200, TestJSON.session(access: "rotated", refresh: "refresh-2"))
        }
        transport.delayResponses(by: .milliseconds(150))
        let (client, store) = makeClient(session: staleSession, transport: transport)

        async let first = client.accessToken()
        async let second = client.accessToken()
        async let third = client.accessToken()
        let tokens = try await [first, second, third]

        XCTAssertEqual(tokens, ["rotated", "rotated", "rotated"])
        XCTAssertEqual(transport.requests.count, 1, "the refresh must be coalesced: Supabase revokes reused refresh tokens")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-2")
        let user = await client.currentUser
        XCTAssertEqual(user?.id, "user-1")
    }

    func testRejectedRefreshSignsOutAndTellsTheHandler() async throws {
        let transport = FakeTransport { _ in (401, TestJSON.object(["error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"])) }
        let (client, store) = makeClient(session: staleSession, transport: transport)
        let signedOut = expectation(description: "signed-out handler")
        await client.setSignedOutHandler { signedOut.fulfill() }

        do {
            _ = try await client.accessToken()
            XCTFail("expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        await fulfillment(of: [signedOut], timeout: 1)
        XCTAssertNil(store.load())
        let user = await client.currentUser
        XCTAssertNil(user)
    }

    func testNetworkFailureDuringRefreshKeepsTheSession() async throws {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let (client, store) = makeClient(session: staleSession, transport: transport)

        do {
            _ = try await client.accessToken()
            XCTFail("expected network")
        } catch {
            XCTAssertEqual(error as? AuthError, .network)
        }
        XCTAssertEqual(store.load()?.refreshToken, "refresh-1")
        let user = await client.currentUser
        XCTAssertEqual(user?.id, "user-1")
    }

    func testSignUpSendsTheNameAndMapsConfirmation() async throws {
        let transport = FakeTransport { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/auth/v1/signup"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["email"] as? String, "sofia@example.edu")
            XCTAssertEqual((body["data"] as? [String: String])?["full_name"], "Sofia")
            return (200, TestJSON.bareUser())
        }
        let (client, store) = makeClient(session: nil, transport: transport)
        let outcome = try await client.signUp(email: "sofia@example.edu", password: "longenough", name: "Sofia")
        XCTAssertEqual(outcome, .confirmationRequired(email: "sofia@example.edu"))
        XCTAssertNil(store.load())
    }

    func testSignInWithAppleSendsProviderTokenAndNonce() async throws {
        let transport = FakeTransport { request in
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/auth/v1/token?grant_type=id_token"))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["provider"], "apple")
            XCTAssertEqual(body["id_token"], "jwt")
            XCTAssertEqual(body["nonce"], "raw-nonce")
            return (200, TestJSON.session(provider: "apple", name: nil))
        }
        let (client, store) = makeClient(session: nil, transport: transport)
        let user = try await client.signInWithApple(idToken: "jwt", rawNonce: "raw-nonce")
        XCTAssertTrue(user.signedInWithApple)
        XCTAssertNil(user.fullName)
        XCTAssertEqual(store.load()?.accessToken, "access")
    }

    func testSignInErrorsSurfaceAsTypedErrors() async throws {
        let transport = FakeTransport { _ in (400, TestJSON.object(["error_code": "invalid_credentials", "msg": "Invalid login credentials"])) }
        let (client, _) = makeClient(session: nil, transport: transport)
        do {
            _ = try await client.signIn(email: "a@b.co", password: "wrong")
            XCTFail("expected invalidCredentials")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidCredentials)
        }
    }

    func testSignOutClearsEvenWhenTheServerFails() async throws {
        let transport = FakeTransport { _ in throw URLError(.timedOut) }
        let (client, store) = makeClient(session: staleSession, transport: transport)
        await client.signOut()
        XCTAssertNil(store.load())
        XCTAssertEqual(transport.requests("POST", pathContaining: "/auth/v1/logout").count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer stale")
    }
}
