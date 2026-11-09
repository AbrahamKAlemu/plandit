import XCTest
@testable import Plandit

/// The review round: spurious dirty flags, edits during a pull, teardown, deletion, unreadable
/// cloud copies, legacy merges, 401 handling, stale refreshes, and event timing.
@MainActor final class SyncReviewTests: XCTestCase {
    private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    private final class SlowExtractor: PlaceExtracting, @unchecked Sendable {
        var calls = 0
        let delay: Duration

        init(delay: Duration) { self.delay = delay }

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            calls += 1
            try? await Task.sleep(for: delay)
            return ExtractionResult(candidates: [])
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    private final class Recorder {
        var events: [UsageEvent] = []
    }

    // One instance per test method, so one directory per test.
    private let directory = FileManager.default.temporaryDirectory.appending(path: "SyncReviewTests-\(UUID().uuidString)")

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Helpers

    private let user = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")

    private var ownPost: SavedPost {
        SavedPost(
            url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000900")!,
            platform: .tiktok, savedAt: .now, status: .ready, place: SampleData.levain, estimatedCost: 6
        )
    }

    private var processingPost: SavedPost {
        SavedPost(url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000901")!, platform: .tiktok, savedAt: .now, status: .processing)
    }

    private func api(_ transport: FakeTransport, tokenProvider: any AccessTokenProviding = FakeTokenProvider()) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: tokenProvider, transport: transport)
    }

    private func makeStore(storage: SnapshotStore, name: String = "Local") -> PlanditStore {
        var snapshot = AccountSeed.snapshot(legacy: nil, name: name)
        snapshot.saved = [SampleData.levainPost]
        return PlanditStore(snapshot: snapshot, extractor: NoExtractor(), storage: storage)
    }

    private func coordinator(_ transport: FakeTransport, store: PlanditStore, debounce: Duration = .milliseconds(50), pullInterval: TimeInterval = 0) -> SyncCoordinator {
        SyncCoordinator(
            userID: "user-1", client: SnapshotSyncClient(api: api(transport)),
            stateStore: .default(in: directory), store: store, debounce: debounce, minimumPullInterval: pullInterval
        )
    }

    private func remoteResponse(_ snapshot: StoreSnapshot, version: Int) throws -> Data {
        let data = try JSONSerialization.jsonObject(with: SnapshotStore.encode(snapshot)) as! [String: Any]
        return TestJSON.object(["version": version, "data": data])
    }

    private func bootstrap(_ transport: FakeTransport, user: AuthUser? = nil, extractor: any PlaceExtracting = NoExtractor(), legacy: SnapshotStore? = nil) async -> AccountSession {
        let user = user ?? self.user
        return await AccountSession.bootstrap(
            user: user, profileName: nil,
            api: PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: user.id, tokenProvider: FakeTokenProvider(), transport: transport),
            directory: directory,
            legacyStore: legacy ?? SnapshotStore(url: directory.appending(path: "no-legacy.json")),
            extractor: extractor
        )
    }

    private func staleSessionClient(_ transport: FakeTransport, access: String = "stale") -> (SupabaseAuthClient, InMemoryAuthSessionStore) {
        let session = AuthSession(accessToken: access, refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600), user: user)
        let store = InMemoryAuthSessionStore(session: session)
        return (SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: store), store)
    }

    // MARK: - 1. Spurious dirty

    func testFlushingWithoutAChangeNeitherDirtiesNorPushes() async throws {
        let transport = FakeTransport { _ in (500, Data()) }
        let store = makeStore(storage: SnapshotStore(url: directory.appending(path: "store.json")))
        store.persistNow()
        let sync = coordinator(transport, store: store)
        sync.start(version: 5, dirty: false)

        store.flush() // app switch with nothing pending
        store.persistNow() // same content written again
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(sync.state, SyncState(version: 5, dirty: false))
        XCTAssertTrue(transport.requests.isEmpty)

        store.updateProfile { $0.homeBase = "Harlem" }
        store.flush()
        XCTAssertTrue(sync.state.dirty, "a real change still counts")
    }

    // MARK: - 2. Edit during a foreground pull

    func testAnEditDuringTheForegroundFetchIsPushedNotOverwritten() async throws {
        let store = makeStore(storage: SnapshotStore(url: directory.appending(path: "store.json")))
        let serverData = try remoteResponse(AccountSeed.snapshot(legacy: nil, name: "Server"), version: 9)
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? (200, serverData) : (200, TestJSON.object(["version": 10]))
        }
        transport.delayResponses(by: .milliseconds(300)) { $0.httpMethod == "GET" }
        let sync = coordinator(transport, store: store, debounce: .seconds(2))
        sync.start(version: 4, dirty: false)

        let pull = Task { await sync.appBecameActive() }
        try await Task.sleep(for: .milliseconds(100))
        store.updateProfile { $0.homeBase = "Harlem" }
        store.flush()
        XCTAssertTrue(sync.state.dirty)
        await pull.value

        XCTAssertEqual(store.profile.name, "Local")
        XCTAssertEqual(store.profile.homeBase, "Harlem")
        XCTAssertEqual(sync.state, SyncState(version: 10, dirty: false))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)
    }

    // MARK: - 3. Teardown and account binding

    func testATornDownSessionWritesNothingAnywhere() async throws {
        let transport = FakeTransport { request in
            switch request.httpMethod {
            case "GET": return (404, Data())
            case "PUT": return (200, TestJSON.object(["version": 1]))
            default: return (201, Data())
            }
        }
        let session = await bootstrap(transport)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)

        session.tearDown()
        _ = try session.store.save(url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000902")!)
        session.store.updateProfile { $0.homeBase = "Harlem" }
        session.store.flush()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)
        XCTAssertTrue(transport.requests("POST", pathContaining: "events").isEmpty)
        let onDisk = SnapshotStore(url: AccountSeed.storeURL(for: "user-1", in: directory)).load()
        XCTAssertEqual(onDisk?.saved.count, 0)
        XCTAssertEqual(onDisk?.profile.homeBase, "")
        XCTAssertEqual(session.sync?.state, SyncState(version: 1, dirty: false))
    }

    func testATokenForAnotherAccountIsRefused() async throws {
        let transport = FakeTransport { _ in (500, Data()) }
        let (client, store) = staleSessionClient(transport)
        do {
            _ = try await client.accessToken(for: "user-2", rejected: nil)
            XCTFail("expected accountMismatch")
        } catch {
            XCTAssertEqual(error as? AuthError, .accountMismatch)
        }
        await client.sessionRejected(for: "user-2")
        XCTAssertNotNil(store.load(), "another account's rejection does not sign this one out")
        let token = try await client.accessToken(for: "user-1", rejected: nil)
        XCTAssertEqual(token, "stale")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - 4. Deletion

    func testADeletedAccountLeavesNoFileEvenAfterALateExtractionResult() async throws {
        let serverData = try remoteResponse(StoreSnapshot(saved: [processingPost], today: .empty(for: .now, budget: 60), profile: AccountSeed.newProfile(name: "Sofia"), pastPlans: [], visited: []), version: 2)
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? (200, serverData) : (200, TestJSON.object(["version": 3]))
        }
        let extractor = SlowExtractor(delay: .milliseconds(300))
        let session = await bootstrap(transport, extractor: extractor)
        let file = AccountSeed.storeURL(for: "user-1", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path()))
        try await Task.sleep(for: .milliseconds(50)) // the extraction task starts
        XCTAssertEqual(extractor.calls, 1)

        session.removeLocalData()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()))
        XCTAssertEqual(SyncStateStore.default(in: directory).state(for: "user-1"), .fresh)

        try await Task.sleep(for: .milliseconds(500)) // the extraction finishes now
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()), "the late result must not recreate the file")
        XCTAssertTrue(transport.requests("PUT", pathContaining: "snapshot").isEmpty)
        XCTAssertEqual(SyncStateStore.default(in: directory).state(for: "user-1"), .fresh)
    }

    // MARK: - 5. Unreadable cloud copy

    func testAnUnreadableServerCopyIsNeverPushedOver() async throws {
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? (200, TestJSON.object(["version": 3, "data": ["garbage": true]])) : (500, Data())
        }
        let legacy = SnapshotStore(url: directory.appending(path: "plandit-store.json"))
        try legacy.save(StoreSnapshot(saved: [ownPost], today: SampleData.dayPlan, profile: SampleData.profile, pastPlans: [], visited: []))
        let session = await bootstrap(transport, legacy: legacy)

        XCTAssertEqual(session.sync?.isReadOnly, true)
        XCTAssertEqual(session.sync?.state, SyncState(version: 3, dirty: false))
        XCTAssertEqual(session.store.profile.name, "Sofia", "shown from the seed")

        session.store.updateProfile { $0.homeBase = "Harlem" }
        session.store.flush()
        await session.sync?.appBecameActive()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(transport.requests("PUT", pathContaining: "snapshot").isEmpty)
        XCTAssertEqual(session.sync?.state.dirty, false)
        XCTAssertTrue(legacy.exists, "the pre-account file waits for a bootstrap that can sync")
    }

    // MARK: - 6. Legacy merge into an adopted cloud copy

    func testLegacySavesMergeIntoTheAdoptedCloudCopyOnce() async throws {
        let legacy = SnapshotStore(url: directory.appending(path: "plandit-store.json"))
        let own = ownPost
        try legacy.save(StoreSnapshot(saved: SampleData.savedPosts + [own], today: SampleData.dayPlan, profile: SampleData.profile, pastPlans: [], visited: []))
        var cloud = AccountSeed.snapshot(legacy: nil, name: "Cloud")
        cloud.saved = [SampleData.tacosPost]
        let serverData = try remoteResponse(cloud, version: 5)
        let transport = FakeTransport { request in
            switch request.httpMethod {
            case "GET": return request.value(forHTTPHeaderField: "Authorization") == nil ? (500, Data()) : (200, serverData)
            case "PUT": return (200, TestJSON.object(["version": 6]))
            default: return (500, Data())
            }
        }

        let first = await bootstrap(transport, legacy: legacy)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(Set(first.store.saved.map(\.canonicalURL)), [SampleData.tacosPost.canonicalURL, own.canonicalURL])
        XCTAssertEqual(first.store.profile.name, "Cloud")
        XCTAssertFalse(legacy.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "plandit-store.migrated.json").path()))
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)
        XCTAssertEqual(first.sync?.state, SyncState(version: 6, dirty: false))
        first.tearDown()

        transport.respond { request in
            switch request.httpMethod {
            case "GET": return (404, Data())
            case "PUT": return (200, TestJSON.object(["version": 1]))
            default: return (500, Data())
            }
        }
        let second = await bootstrap(transport, user: AuthUser(id: "user-2", email: "b@example.edu", fullName: "B", provider: "email"), legacy: legacy)
        XCTAssertTrue(second.store.saved.isEmpty, "a second account inherits nothing")
        second.tearDown()
    }

    // MARK: - 7. 401 from the API

    private func apiTransport(putAfterRefresh: @escaping @Sendable (URLRequest) -> (Int, Data)) -> FakeTransport {
        FakeTransport { request in
            if request.url!.absoluteString.contains("grant_type=refresh_token") {
                return (200, TestJSON.session(access: "rotated", refresh: "refresh-2"))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale" {
                return (401, TestJSON.object(["detail": "Invalid token."]))
            }
            return putAfterRefresh(request)
        }
    }

    func testA401ForcesOneRefreshAndOneRetry() async throws {
        let transport = apiTransport { _ in (200, TestJSON.object(["version": 2])) }
        let (client, store) = staleSessionClient(transport)
        let version = try await SnapshotSyncClient(api: api(transport, tokenProvider: client)).push(Data("{}".utf8))

        XCTAssertEqual(version, 2)
        XCTAssertEqual(transport.requests("POST", pathContaining: "refresh_token").count, 1)
        let puts = transport.requests("PUT", pathContaining: "snapshot")
        XCTAssertEqual(puts.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer stale", "Bearer rotated"])
        XCTAssertEqual(store.load()?.accessToken, "rotated")
    }

    func testASecond401EndsTheSession() async throws {
        let transport = apiTransport { _ in (401, TestJSON.object(["detail": "Invalid token."])) }
        let (client, store) = staleSessionClient(transport)
        let signedOut = expectation(description: "signed-out handler")
        await client.setSignedOutHandler { signedOut.fulfill() }

        do {
            _ = try await SnapshotSyncClient(api: api(transport, tokenProvider: client)).push(Data("{}".utf8))
            XCTFail("expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        await fulfillment(of: [signedOut], timeout: 1)
        XCTAssertNil(store.load())
        XCTAssertEqual(transport.requests("POST", pathContaining: "refresh_token").count, 1)
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 2)
    }

    /// The production shape when the account row is gone: the API says so on the first try, and
    /// a refresh (which must not happen) would be refused with 400.
    private func deletedAccountTransport(_ method: String) -> FakeTransport {
        FakeTransport { request in
            if request.url!.absoluteString.contains("grant_type=refresh_token") {
                return (400, TestJSON.object(["error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"]))
            }
            switch request.httpMethod {
            case method, "GET": return (401, TestJSON.object(["detail": "Account deleted."]))
            default: return (201, Data())
            }
        }
    }

    /// An account model wired to a signed-in client and a bootstrapped session, as the app does.
    private func signedInAccount(_ transport: FakeTransport) async -> (AccountModel, AccountSession, InMemoryAuthSessionStore) {
        let (client, sessionStore) = staleSessionClient(transport, access: "valid")
        let account = AccountModel(client: client, apiBaseURL: TestJSON.configuration.apiBaseURL, transport: transport)
        await account.start()
        XCTAssertEqual(account.state, .signedIn(user))
        let session = await AccountSession.bootstrap(
            user: user, profileName: nil, api: account.api(for: user.id), directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "no-legacy.json")), extractor: NoExtractor()
        )
        account.onAccountDeleted = { _ in session.removeLocalData() }
        return (account, session, sessionStore)
    }

    func testDeletingAnAlreadyDeletedAccountCountsAsDone() async throws {
        let transport = FakeTransport { request in // a normal bootstrap first
            request.httpMethod == "GET" ? (404, Data()) : (200, TestJSON.object(["version": 1]))
        }
        let (account, _, sessionStore) = await signedInAccount(transport)
        try await Task.sleep(for: .milliseconds(300)) // the seed push lands
        let file = AccountSeed.storeURL(for: "user-1", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path()))
        transport.respond(deletedAccountTransport("DELETE").handlerForTests)

        await account.deleteAccount()

        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/me/").count, 1, "no retry")
        XCTAssertTrue(transport.requests("POST", pathContaining: "refresh_token").isEmpty, "no refresh")
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage)
        XCTAssertNil(sessionStore.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()))
        XCTAssertEqual(SyncStateStore.default(in: directory).state(for: "user-1"), .fresh)
    }

    func testASnapshotPushLearningTheAccountIsGoneSignsOutAndRemovesLocalData() async throws {
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? (404, Data()) : (200, TestJSON.object(["version": 1]))
        }
        let (account, session, sessionStore) = await signedInAccount(transport)
        try await Task.sleep(for: .milliseconds(300)) // the seed push lands
        let file = AccountSeed.storeURL(for: "user-1", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path()))
        transport.respond(deletedAccountTransport("PUT").handlerForTests)

        session.store.updateProfile { $0.homeBase = "Harlem" }
        session.store.flush()
        await session.sync?.pushNow()
        try await Task.sleep(for: .milliseconds(100)) // the handler hops to the main actor

        XCTAssertTrue(transport.requests("POST", pathContaining: "refresh_token").isEmpty, "no refresh")
        XCTAssertEqual(account.state, .signedOut)
        XCTAssertNil(account.errorMessage)
        XCTAssertNil(sessionStore.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()))
        XCTAssertEqual(SyncStateStore.default(in: directory).state(for: "user-1"), .fresh)
        XCTAssertEqual(session.store.isClosed, true)
    }

    func testAnOrdinarySecond401OnDeleteEndsTheSession() async throws {
        let transport = apiTransport { _ in (401, TestJSON.object(["detail": "Invalid token."])) }
        let (client, store) = staleSessionClient(transport)
        do {
            try await api(transport, tokenProvider: client).deleteAccount()
            XCTFail("expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        XCTAssertNil(store.load())
        XCTAssertEqual(transport.requests("DELETE", pathContaining: "api/me/").count, 2)
    }

    func testA503OnPushKeepsDirtyAndTheSession() async throws {
        let transport = FakeTransport { request in
            request.httpMethod == "GET" ? (404, Data()) : (503, TestJSON.object(["detail": "Try again later."]))
        }
        let (account, session, sessionStore) = await signedInAccount(transport)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(session.sync?.state, SyncState(version: nil, dirty: true))
        XCTAssertEqual(account.state, .signedIn(user))
        XCTAssertNotNil(sessionStore.load())
        XCTAssertTrue(transport.requests("POST", pathContaining: "refresh_token").isEmpty)
        session.tearDown()
    }

    // MARK: - 8. Stale refresh result

    func testARefreshThatFinishesAfterSignOutIsDropped() async throws {
        let transport = FakeTransport { _ in (200, TestJSON.session(access: "rotated", refresh: "refresh-2")) }
        transport.delayResponses(by: .milliseconds(200))
        let session = AuthSession(accessToken: "stale", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(30), user: user)
        let store = InMemoryAuthSessionStore(session: session)
        let client = SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: store)

        let token = Task { try await client.accessToken() }
        try await Task.sleep(for: .milliseconds(50))
        await client.clearSession()
        let result = await token.result

        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? AuthError, .sessionExpired) }
        XCTAssertNil(store.load(), "the rotated session must not come back")
        let user = await client.currentUser
        XCTAssertNil(user)
    }

    func testARejectedRefreshForAReplacedSessionDoesNotSignTheNewOneOut() async throws {
        let transport = FakeTransport { request in
            if request.url!.absoluteString.contains("grant_type=refresh_token") {
                return (401, TestJSON.object(["error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"]))
            }
            return (200, TestJSON.session(access: "second", refresh: "refresh-9"))
        }
        transport.delayResponses(by: .milliseconds(200)) { $0.url!.absoluteString.contains("refresh_token") }
        let session = AuthSession(accessToken: "stale", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(30), user: user)
        let store = InMemoryAuthSessionStore(session: session)
        let client = SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: store)
        let signedOut = expectation(description: "the signed-out handler must not fire")
        signedOut.isInverted = true
        await client.setSignedOutHandler { signedOut.fulfill() }

        let refresh = Task { try await client.accessToken() }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await client.signIn(email: "sofia@example.edu", password: "longenough") // a new session meanwhile
        let result = await refresh.result
        await fulfillment(of: [signedOut], timeout: 0.3)

        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? AuthError, .sessionExpired) }
        XCTAssertEqual(store.load()?.refreshToken, "refresh-9", "the new session stays")
        let token = try await client.accessToken()
        XCTAssertEqual(token, "second")
    }

    // MARK: - 9. Back to sign-in

    func testShowSignInForgetsThePendingName() async {
        let transport = FakeTransport { _ in (200, TestJSON.bareUser()) }
        let client = SupabaseAuthClient(configuration: TestJSON.configuration, transport: transport, sessionStore: InMemoryAuthSessionStore(session: nil))
        let account = AccountModel(client: client, apiBaseURL: nil, state: .signedOut)

        await account.signUp(email: "sofia@example.edu", password: "longenough", name: "Sofia")
        XCTAssertEqual(account.state, .awaitingConfirmation(email: "sofia@example.edu"))
        XCTAssertEqual(account.pendingProfileName, "Sofia")

        account.showSignIn()
        XCTAssertNil(account.pendingProfileName)
        XCTAssertEqual(account.state, .signedOut)
    }

    // MARK: - 10. Events and extraction

    func testAFailedVideoSaveEmitsNoEvent() async {
        let recorder = Recorder()
        let store = PlanditStore(snapshot: AccountSeed.snapshot(legacy: nil, name: "A"), extractor: NoExtractor(), storage: nil) { recorder.events.append($0) }
        do {
            _ = try await store.saveVideo(fileURL: directory.appending(path: "missing.mov"))
            XCTFail("expected the save to fail")
        } catch {}
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testReplacingTheStoreDoesNotRestartARunningExtraction() async throws {
        let extractor = SlowExtractor(delay: .milliseconds(200))
        let snapshot = StoreSnapshot(saved: [processingPost], today: .empty(for: .now, budget: 60), profile: AccountSeed.newProfile(name: "A"), pastPlans: [], visited: [])
        let store = PlanditStore(snapshot: snapshot, extractor: extractor, storage: SnapshotStore(url: directory.appending(path: "store.json")))
        try await Task.sleep(for: .milliseconds(50)) // the extraction task starts
        XCTAssertEqual(extractor.calls, 1)

        store.replace(with: snapshot)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(extractor.calls, 1, "still in flight")

        try await Task.sleep(for: .milliseconds(400))
        store.replace(with: snapshot)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(extractor.calls, 2, "finished, so a fresh copy starts again")
    }
}
