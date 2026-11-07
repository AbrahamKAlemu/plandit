import Foundation

/// One signed-in account's store, local file and sync. Built on sign-in, torn down on sign-out.
@MainActor
final class AccountSession {
    let userID: String
    let store: PlanditStore
    let sync: SyncCoordinator?
    private let storage: SnapshotStore

    init(userID: String, store: PlanditStore, sync: SyncCoordinator?, storage: SnapshotStore) {
        self.userID = userID
        self.store = store
        self.sync = sync
        self.storage = storage
    }

    /// `-skipAuth`: the pre-account file with its sample data, no network at all.
    static func local(userID: String) -> AccountSession {
        AccountSession(userID: userID, store: PlanditStore.load(), sync: nil, storage: .default)
    }

    /// Sign-in: ask the server for the account's copy and decide between it, the local file and a
    /// fresh seed (see `SyncDecision`). Without an API client the account is local-only.
    ///
    /// Whichever copy wins, the person's own saves from the pre-account file (if it is still there)
    /// are merged in and the file is retired, so they are never lost and never inherited twice.
    static func bootstrap(
        user: AuthUser,
        profileName: String?,
        api: PlanditAPIClient?,
        directory: URL = SnapshotStore.directory,
        legacyStore: SnapshotStore = .default,
        extractor: any PlaceExtracting = FixturePlaceExtractor()
    ) async -> AccountSession {
        let storage = SnapshotStore(url: AccountSeed.storeURL(for: user.id, in: directory))
        let name = (user.fullName ?? profileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = AccountSeed.legacySnapshot(in: legacyStore)
        let legacyPosts = legacy.map(AccountSeed.ownPosts) ?? []
        let seed = { AccountSeed.snapshot(legacy: legacy, name: name) }

        guard let api else {
            let snapshot = AccountSeed.merging(legacyPosts, into: storage.load() ?? seed()).snapshot
            let store = PlanditStore(snapshot: snapshot, extractor: extractor, storage: storage)
            store.persistNow()
            store.rollOverIfNeeded()
            AccountSeed.retireLegacyFile(in: legacyStore)
            return AccountSession(userID: user.id, store: store, sync: nil, storage: storage)
        }

        let eventClient = UsageEventClient(api: api)
        let client = SnapshotSyncClient(api: api)
        let stateStore = SyncStateStore.default(in: directory)
        let previous = stateStore.state(for: user.id)
        let remote: Result<RemoteSnapshot?, Error>
        do {
            remote = .success(try await client.fetch())
        } catch {
            remote = .failure(error)
        }

        var snapshot: StoreSnapshot
        var version = previous.version
        var dirty: Bool
        var readOnly = false
        switch SyncDecision.initial(hasLocalFile: storage.exists, state: previous, remote: remote) {
        case .adoptServer(let remoteSnapshot):
            version = remoteSnapshot.version
            if let decoded = try? SnapshotStore.decode(remoteSnapshot.data) {
                snapshot = decoded
                dirty = false
            } else {
                // A copy this build cannot read, probably written by a newer one: show what we
                // have, but never push over it.
                snapshot = storage.load() ?? seed()
                dirty = false
                readOnly = true
            }
        case .keepLocalAndPush, .seedAndPush:
            snapshot = storage.load() ?? seed()
            dirty = true
        case .keepLocalOffline:
            if let local = storage.load() {
                snapshot = local
                dirty = previous.dirty
            } else {
                snapshot = seed()
                dirty = true
            }
        case .seedOffline:
            snapshot = seed()
            dirty = true
        }

        if !readOnly {
            let merged = AccountSeed.merging(legacyPosts, into: snapshot)
            snapshot = merged.snapshot
            if merged.added > 0 { dirty = true }
        }

        let store = PlanditStore(snapshot: snapshot, extractor: extractor, storage: storage) { event in
            Task { try? await eventClient.send(event) }
        }
        store.persistNow()
        let sync = SyncCoordinator(userID: user.id, client: client, stateStore: stateStore, store: store)
        sync.start(version: version, dirty: dirty, readOnly: readOnly)
        store.rollOverIfNeeded()
        if !readOnly {
            // Kept while read-only: a later bootstrap that can sync again will take it.
            AccountSeed.retireLegacyFile(in: legacyStore)
        }
        return AccountSession(userID: user.id, store: store, sync: sync, storage: storage)
    }

    /// Detaches the store from the file, the sync and the events API. Idempotent; the session is
    /// unusable afterwards.
    func tearDown() {
        store.close()
        sync?.close()
    }

    /// After the server deleted the account: nothing of it stays on this phone.
    func removeLocalData() {
        tearDown()
        sync?.forget()
        storage.reset()
    }
}
