import XCTest
@testable import Plandit

/// Deleting an account signed in with Apple: a fresh authorization code goes with the request so
/// the server can revoke Apple's tokens. Cancel deletes nothing quietly; a failure shows
/// `deleteFailed` without a request; email accounts never see the sheet.
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

    private let appleUser = AuthUser(id: "user-1", email: nil, fullName: nil, provider: "apple")
    private let emailUser = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")

    /// The app's wiring: a signed-in client with a valid session, the fake sheet, one transport.
    private func signedInAccount(
        _ user: AuthUser,
        reauthorizer: FakeAppleReauthorizer,
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
        let reauthorizer = FakeAppleReauthorizer(.code("c1a2b3.0.rrtx.fresh-code"))
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        let deletes = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(body(of: deletes[0]), ["apple_authorization_code": "c1a2b3.0.rrtx.fresh-code"])
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

    func testAnAppleSheetFailureShowsDeleteFailedAndSendsNothing() async throws {
        let transport = deleteTransport()
        let reauthorizer = FakeAppleReauthorizer(.failed)
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(reauthorizer.calls, 1)
        XCTAssertTrue(transport.requests.isEmpty, "nothing sent")
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertEqual(account.errorMessage, AuthCopy.deleteFailed)
        XCTAssertFalse(account.isBusy)
        XCTAssertNotNil(store.load())
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
        let reauthorizer = FakeAppleReauthorizer(.code("c1a2b3.0.rrtx.fresh-code"))
        let (account, store) = await signedInAccount(appleUser, reauthorizer: reauthorizer, transport: transport)

        await account.deleteAccount()

        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/me/").count, 1)
        XCTAssertEqual(account.state, .signedIn(appleUser))
        XCTAssertEqual(account.errorMessage, AuthCopy.deleteFailed)
        XCTAssertNotNil(store.load())
    }

    // MARK: - PlanditAPIClient

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }

    func testDeleteAccountSendsTheCodeAsJSONOnlyWhenThereIsOne() async throws {
        let transport = FakeTransport { _ in (204, Data()) }

        try await api(transport).deleteAccount(appleAuthorizationCode: "c1a2b3.0.rrtx.fresh-code")
        try await api(transport).deleteAccount(appleAuthorizationCode: nil)
        try await api(transport).deleteAccount()

        let requests = transport.requests("DELETE", pathContaining: "api/me/")
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(body(of: requests[0]), ["apple_authorization_code": "c1a2b3.0.rrtx.fresh-code"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        for request in requests.dropFirst() {
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
        }
    }
}
