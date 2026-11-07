import XCTest
@testable import Plandit

final class SyncCoordinatorTests: XCTestCase {
    @MainActor private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "SyncCoordinatorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Decisions

    func testInitialDecisions() {
        let remote = RemoteSnapshot(version: 3, updatedAt: nil, data: Data("{}".utf8))
        let clean = SyncState(version: 2, dirty: false)
        let dirty = SyncState(version: 2, dirty: true)
        let offline: Result<RemoteSnapshot?, Error> = .failure(APIError.network)

        XCTAssertEqual(SyncDecision.initial(hasLocalFile: true, state: clean, remote: .success(remote)), .adoptServer(remote))
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: false, state: clean, remote: .success(remote)), .adoptServer(remote))
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: true, state: dirty, remote: .success(remote)), .keepLocalAndPush)
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: false, state: dirty, remote: .success(remote)), .adoptServer(remote), "dirty without a file has nothing to keep")
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: false, state: clean, remote: .success(nil)), .seedAndPush)
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: true, state: clean, remote: .success(nil)), .keepLocalAndPush)
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: true, state: clean, remote: offline), .keepLocalOffline)
        XCTAssertEqual(SyncDecision.initial(hasLocalFile: false, state: clean, remote: offline), .seedOffline)
    }

    // MARK: - Coordinator with a fake transport

    @MainActor private func makeStore(storage: SnapshotStore, profileName: String = "Sofia") -> PlanditStore {
        var snapshot = AccountSeed.snapshot(legacy: nil, name: profileName)
        snapshot.saved = [SampleData.levainPost]
        return PlanditStore(snapshot: snapshot, extractor: NoExtractor(), storage: storage)
    }

    private func api(_ transport: FakeTransport) -> PlanditAPIClient {
        PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: "user-1", tokenProvider: FakeTokenProvider(), transport: transport)
    }

    @MainActor func testLocalChangeIsPushedAfterTheDebounceAndClearsDirty() async throws {
        let transport = FakeTransport { request in
            guard request.httpMethod == "PUT" else { return (404, Data()) }
            return (200, TestJSON.object(["version": 7, "updated_at": "2026-11-07T15:04:05Z"]))
        }
        let storage = SnapshotStore(url: directory.appending(path: "store.json"))
        let store = makeStore(storage: storage)
        let coordinator = SyncCoordinator(
            userID: "user-1", client: SnapshotSyncClient(api: api(transport)),
            stateStore: .default(in: directory), store: store, debounce: .milliseconds(50)
        )
        coordinator.start(version: nil, dirty: false)

        store.updateProfile { $0.homeBase = "Harlem" }
        XCTAssertFalse(coordinator.state.dirty, "nothing written yet: the store coalesces writes")
        try await Task.sleep(for: .milliseconds(700))

        let puts = transport.requests("PUT", pathContaining: "api/me/snapshot/")
        XCTAssertEqual(puts.count, 1)
        XCTAssertEqual(puts.first?.url?.absoluteString, "https://api.example/api/me/snapshot/")
        XCTAssertEqual(puts.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: puts.first!.httpBody!) as? [String: Any])
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotStore.encode(store.snapshot)) as? [String: Any])
        XCTAssertEqual(payload as NSDictionary, expected as NSDictionary, "`data` is the store's own JSON shape")
        XCTAssertEqual((payload["profile"] as? [String: Any])?["homeBase"] as? String, "Harlem")
        XCTAssertEqual(coordinator.state, SyncState(version: 7, dirty: false))
        XCTAssertEqual(SyncStateStore.default(in: directory).state(for: "user-1"), SyncState(version: 7, dirty: false))
    }

    @MainActor func testFailedPushKeepsDirtyAndRetriesOnForeground() async throws {
        let transport = FakeTransport { _ in (503, Data()) }
        let storage = SnapshotStore(url: directory.appending(path: "store.json"))
        let store = makeStore(storage: storage)
        let coordinator = SyncCoordinator(
            userID: "user-1", client: SnapshotSyncClient(api: api(transport)),
            stateStore: .default(in: directory), store: store, debounce: .milliseconds(50)
        )
        coordinator.start(version: 2, dirty: false)

        store.updateProfile { $0.homeBase = "Harlem" }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(coordinator.state, SyncState(version: 2, dirty: true))

        transport.respond { request in
            request.httpMethod == "PUT" ? (200, TestJSON.object(["version": 3])) : (404, Data())
        }
        await coordinator.appBecameActive()
        XCTAssertEqual(coordinator.state, SyncState(version: 3, dirty: false))
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 2)
    }

    @MainActor func testForegroundAdoptsANewerServerCopyWhenClean() async throws {
        let storage = SnapshotStore(url: directory.appending(path: "store.json"))
        let store = makeStore(storage: storage, profileName: "Local")
        var serverSnapshot = AccountSeed.snapshot(legacy: nil, name: "Server")
        serverSnapshot.saved = [SampleData.tacosPost]
        let serverData = try SnapshotStore.encode(serverSnapshot)
        let transport = FakeTransport { request in
            guard request.httpMethod == "GET" else { return (500, Data()) }
            let data = try JSONSerialization.jsonObject(with: serverData) as! [String: Any]
            return (200, TestJSON.object(["version": 9, "updated_at": "2026-11-07T15:04:05Z", "data": data]))
        }
        let coordinator = SyncCoordinator(
            userID: "user-1", client: SnapshotSyncClient(api: api(transport)),
            stateStore: .default(in: directory), store: store, debounce: .milliseconds(50), minimumPullInterval: 0
        )
        coordinator.start(version: 4, dirty: false)

        await coordinator.appBecameActive()

        XCTAssertEqual(store.profile.name, "Server")
        XCTAssertEqual(store.saved.map(\.id), [SampleData.tacosPost.id])
        XCTAssertEqual(coordinator.state, SyncState(version: 9, dirty: false), "adopting is not a local change")
        XCTAssertEqual(storage.load()?.profile.name, "Server", "the server copy is written to the account's file")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(transport.requests("PUT", pathContaining: "snapshot").isEmpty)
    }

    @MainActor func testForegroundIgnoresAnOlderServerCopy() async throws {
        let storage = SnapshotStore(url: directory.appending(path: "store.json"))
        let store = makeStore(storage: storage, profileName: "Local")
        let serverData = try SnapshotStore.encode(AccountSeed.snapshot(legacy: nil, name: "Server"))
        let transport = FakeTransport { _ in
            let data = try JSONSerialization.jsonObject(with: serverData) as! [String: Any]
            return (200, TestJSON.object(["version": 4, "data": data]))
        }
        let coordinator = SyncCoordinator(
            userID: "user-1", client: SnapshotSyncClient(api: api(transport)),
            stateStore: .default(in: directory), store: store, minimumPullInterval: 0
        )
        coordinator.start(version: 4, dirty: false)
        await coordinator.appBecameActive()
        XCTAssertEqual(store.profile.name, "Local")
    }

    // MARK: - Sign-in bootstrap

    private func user(_ id: String = "user-1") -> AuthUser {
        AuthUser(id: id, email: "sofia@example.edu", fullName: "Sofia", provider: "email")
    }

    @MainActor func testBootstrapSeedsAndPushesWhenTheServerHasNothing() async throws {
        let transport = FakeTransport { request in
            switch request.httpMethod {
            case "GET": return (404, TestJSON.object(["detail": "No snapshot yet."]))
            case "PUT": return (200, TestJSON.object(["version": 1]))
            default: return (500, Data())
            }
        }
        let session = await AccountSession.bootstrap(
            user: user(), profileName: nil, api: api(transport), directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json")), extractor: NoExtractor()
        )
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(session.store.saved.isEmpty)
        XCTAssertTrue(session.store.today.stops.isEmpty)
        XCTAssertTrue(session.store.pastPlans.isEmpty)
        XCTAssertEqual(session.store.profile, AccountSeed.newProfile(name: "Sofia"))
        XCTAssertEqual(session.store.stats, .empty)
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)
        XCTAssertEqual(session.sync?.state, SyncState(version: 1, dirty: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AccountSeed.storeURL(for: "user-1", in: directory).path()))
    }

    @MainActor func testBootstrapAdoptsTheServerCopyWhenNotDirty() async throws {
        var serverSnapshot = AccountSeed.snapshot(legacy: nil, name: "Cloud")
        serverSnapshot.saved = [SampleData.tacosPost]
        let serverData = try SnapshotStore.encode(serverSnapshot)
        let transport = FakeTransport { request in
            guard request.httpMethod == "GET" else { return (500, Data()) }
            let data = try JSONSerialization.jsonObject(with: serverData) as! [String: Any]
            return (200, TestJSON.object(["version": 5, "data": data]))
        }
        let session = await AccountSession.bootstrap(
            user: user(), profileName: nil, api: api(transport), directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json")), extractor: NoExtractor()
        )
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(session.store.profile.name, "Cloud")
        XCTAssertEqual(session.store.saved.map(\.id), [SampleData.tacosPost.id])
        XCTAssertEqual(session.sync?.state, SyncState(version: 5, dirty: false))
        XCTAssertTrue(transport.requests("PUT", pathContaining: "snapshot").isEmpty)
    }

    @MainActor func testBootstrapKeepsDirtyLocalDataAndPushesIt() async throws {
        let storage = SnapshotStore(url: AccountSeed.storeURL(for: "user-1", in: directory))
        var local = AccountSeed.snapshot(legacy: nil, name: "Phone")
        local.saved = [SampleData.levainPost]
        try storage.save(local)
        SyncStateStore.default(in: directory).save(SyncState(version: 2, dirty: true), for: "user-1")
        let serverData = try SnapshotStore.encode(AccountSeed.snapshot(legacy: nil, name: "Cloud"))
        let transport = FakeTransport { request in
            switch request.httpMethod {
            case "GET":
                let data = try JSONSerialization.jsonObject(with: serverData) as! [String: Any]
                return (200, TestJSON.object(["version": 3, "data": data]))
            case "PUT": return (200, TestJSON.object(["version": 4]))
            default: return (500, Data())
            }
        }
        let session = await AccountSession.bootstrap(
            user: user(), profileName: nil, api: api(transport), directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json")), extractor: NoExtractor()
        )
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(session.store.profile.name, "Phone")
        XCTAssertEqual(transport.requests("PUT", pathContaining: "snapshot").count, 1)
        XCTAssertEqual(session.sync?.state, SyncState(version: 4, dirty: false))
    }

    @MainActor func testBootstrapOfflineUsesTheLocalFileOrSeedsDirty() async throws {
        let transport = FakeTransport { _ in throw URLError(.notConnectedToInternet) }
        let legacy = SnapshotStore(url: directory.appending(path: "missing-legacy.json"))

        let first = await AccountSession.bootstrap(user: user(), profileName: "Typed", api: api(transport), directory: directory, legacyStore: legacy, extractor: NoExtractor())
        XCTAssertEqual(first.store.profile.name, "Sofia", "the account's name beats the typed one")
        XCTAssertEqual(first.sync?.state, SyncState(version: nil, dirty: true))
        first.store.updateProfile { $0.homeBase = "Harlem" }
        first.store.flush()

        let second = await AccountSession.bootstrap(user: user(), profileName: nil, api: api(transport), directory: directory, legacyStore: legacy, extractor: NoExtractor())
        XCTAssertEqual(second.store.profile.homeBase, "Harlem")
        XCTAssertEqual(second.sync?.state.dirty, true)
    }

    @MainActor func testBootstrapWithoutAnAPIIsLocalOnly() async {
        let legacy = SnapshotStore(url: directory.appending(path: "missing-legacy.json"))
        let session = await AccountSession.bootstrap(user: user(), profileName: nil, api: nil, directory: directory, legacyStore: legacy, extractor: NoExtractor())
        XCTAssertNil(session.sync)
        XCTAssertTrue(session.store.saved.isEmpty)
    }
}
