import XCTest
@testable import Plandit

/// D-1: `AccountSession.isNewAccount` is true only when bootstrap seeded a brand-new account
/// (`SyncDecision.seedAndPush` or `.seedOffline`): the server had no copy and the phone had no file.
final class NewAccountSignalTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "NewAccountSignalTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private let user = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }

    @MainActor private func bootstrap(_ transport: FakeTransport?) async -> AccountSession {
        let session = await AccountSession.bootstrap(
            user: user, profileName: nil, api: transport.map(api), directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json")), extractor: NoExtractor()
        )
        addTeardownBlock { @MainActor in session.tearDown() }
        return session
    }

    /// The server answers "no snapshot yet" and accepts the seed.
    private func emptyServer() -> FakeTransport {
        FakeTransport { request in
            switch request.httpMethod {
            case "GET": return (404, TestJSON.object(["detail": "No snapshot yet."]))
            case "PUT": return (200, TestJSON.object(["version": 1]))
            default: return (500, Data())
            }
        }
    }

    private func offline() -> FakeTransport {
        FakeTransport { _ in throw URLError(.notConnectedToInternet) }
    }

    @MainActor private func writeLocalFile() throws {
        let storage = SnapshotStore(url: AccountSeed.storeURL(for: "user-1", in: directory))
        try storage.save(AccountSeed.snapshot(legacy: nil, name: "Phone"))
    }

    @MainActor func testSeededWhenTheServerHasNothingAndThePhoneHasNoFile() async {
        let session = await bootstrap(emptyServer())
        XCTAssertTrue(session.isNewAccount)
    }

    @MainActor func testSeededOfflineWhenThePhoneHasNoFile() async {
        let session = await bootstrap(offline())
        XCTAssertTrue(session.isNewAccount)
    }

    @MainActor func testNotNewWhenTheServerHasACopy() async throws {
        let serverData = try SnapshotStore.encode(AccountSeed.snapshot(legacy: nil, name: "Cloud"))
        let transport = FakeTransport { request in
            guard request.httpMethod == "GET" else { return (500, Data()) }
            let data = try JSONSerialization.jsonObject(with: serverData) as! [String: Any]
            return (200, TestJSON.object(["version": 5, "data": data]))
        }
        let session = await bootstrap(transport)
        XCTAssertFalse(session.isNewAccount, "an existing account on a new phone never counts as new")
        XCTAssertEqual(session.store.profile.name, "Cloud", "the decision itself is unchanged")
    }

    @MainActor func testNotNewWhenTheServerHasNothingButThePhoneHasAFile() async throws {
        try writeLocalFile()
        let session = await bootstrap(emptyServer())
        XCTAssertFalse(session.isNewAccount)
        XCTAssertEqual(session.store.profile.name, "Phone")
    }

    @MainActor func testNotNewOfflineWhenThePhoneHasAFile() async throws {
        try writeLocalFile()
        let session = await bootstrap(offline())
        XCTAssertFalse(session.isNewAccount)
    }

    @MainActor func testSecondBootstrapOfTheSameAccountIsNotNew() async {
        let first = await bootstrap(offline())
        XCTAssertTrue(first.isNewAccount)
        first.store.flush()
        first.tearDown()

        let second = await bootstrap(offline())
        XCTAssertFalse(second.isNewAccount, "the first bootstrap left a file on the phone")
    }

    @MainActor func testLocalOnlyBootstrapIsNotNew() async {
        let session = await bootstrap(nil)
        XCTAssertFalse(session.isNewAccount, "without an API there is no sync decision")
    }

    @MainActor func testSkipAuthSessionIsNotNew() {
        let session = AccountSession.local(userID: "local-test-account")
        XCTAssertFalse(session.isNewAccount)
    }
}
