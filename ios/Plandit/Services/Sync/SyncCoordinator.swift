import Foundation
import Observation

/// What this device knows about one account's cloud copy.
nonisolated struct SyncState: Codable, Sendable, Equatable {
    /// Server version this device last pulled or pushed; nil before the first exchange.
    var version: Int?
    /// Local changes the server has not accepted yet.
    var dirty: Bool

    static let fresh = SyncState(version: nil, dirty: false)
}

/// One JSON file next to the store files: `{ "<user-id>": { "version": 3, "dirty": false } }`.
nonisolated struct SyncStateStore: Sendable {
    let url: URL

    static func `default`(in directory: URL) -> SyncStateStore {
        SyncStateStore(url: directory.appending(path: "plandit-sync-state.json"))
    }

    func state(for userID: String) -> SyncState {
        all()[userID] ?? .fresh
    }

    func save(_ state: SyncState, for userID: String) {
        var states = all()
        states[userID] = state
        write(states)
    }

    func remove(userID: String) {
        var states = all()
        states.removeValue(forKey: userID)
        write(states)
    }

    private func all() -> [String: SyncState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SyncState].self, from: data)) ?? [:]
    }

    private func write(_ states: [String: SyncState]) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// How to start an account's store on sign-in, given what the server said.
nonisolated enum SyncDecision: Equatable {
    /// The server copy wins: write it locally and use it.
    case adoptServer(RemoteSnapshot)
    /// This device has unsynced changes (or the server has nothing): keep the local file and push it.
    case keepLocalAndPush
    /// Nothing anywhere: seed a fresh account and push it.
    case seedAndPush
    /// Offline with a local file: use it, push later.
    case keepLocalOffline
    /// Offline and nothing local: seed and mark dirty so the first push uploads it.
    case seedOffline

    static func initial(hasLocalFile: Bool, state: SyncState, remote: Result<RemoteSnapshot?, Error>) -> SyncDecision {
        switch remote {
        case .success(.some(let snapshot)):
            if state.dirty, hasLocalFile { return .keepLocalAndPush }
            return .adoptServer(snapshot)
        case .success(.none):
            return hasLocalFile ? .keepLocalAndPush : .seedAndPush
        case .failure:
            return hasLocalFile ? .keepLocalOffline : .seedOffline
        }
    }
}

/// Keeps one account's local store and its cloud copy in step. Last writer wins, by version.
@Observable
@MainActor
final class SyncCoordinator {
    let userID: String
    private(set) var state: SyncState
    /// The server copy could not be read by this build: show what we have, never push over it.
    private(set) var isReadOnly = false
    /// Torn down with its session: nothing it does from here on reaches the store or the server.
    private(set) var isClosed = false

    @ObservationIgnored private let client: SnapshotSyncClient
    @ObservationIgnored private let stateStore: SyncStateStore
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let minimumPullInterval: TimeInterval
    @ObservationIgnored private weak var store: PlanditStore?
    /// What the store last wrote, when it differs from `synced`.
    @ObservationIgnored private var latest: Data?
    /// The last payload the server accepted or handed us: a write that equals it is not a change.
    @ObservationIgnored private var synced: Data?
    @ObservationIgnored private var pendingPush: Task<Void, Never>?
    @ObservationIgnored private var pushInFlight: Task<Bool, Never>?
    @ObservationIgnored private var isAdopting = false
    @ObservationIgnored private var lastExchange: Date?

    init(
        userID: String,
        client: SnapshotSyncClient,
        stateStore: SyncStateStore,
        store: PlanditStore,
        debounce: Duration = .seconds(2),
        minimumPullInterval: TimeInterval = 10
    ) {
        self.userID = userID
        self.client = client
        self.stateStore = stateStore
        self.store = store
        self.debounce = debounce
        self.minimumPullInterval = minimumPullInterval
        state = stateStore.state(for: userID)
        store.onChange = { [weak self] snapshot in self?.storeDidChange(snapshot) }
    }

    /// Hooked to `PlanditStore.onChange`: a local write that differs from what the server has
    /// marks the account dirty and schedules a push.
    func storeDidChange(_ snapshot: StoreSnapshot) {
        guard !isClosed, !isAdopting, !isReadOnly, let data = try? SnapshotStore.encode(snapshot) else { return }
        if data == synced {
            latest = nil
            return
        }
        latest = data
        setState(SyncState(version: state.version, dirty: true))
        schedulePush()
    }

    /// Call after the store has been written locally. `dirty` means the server must get this
    /// content now; otherwise it is the baseline the server already has. `readOnly` keeps a
    /// server copy this build cannot read: nothing is pushed for the rest of the session.
    func start(version: Int?, dirty: Bool, readOnly: Bool = false) {
        isReadOnly = readOnly
        if readOnly {
            print("Plandit: the cloud copy for this account could not be read; sync is paused until the app is updated.")
        }
        setState(SyncState(version: version, dirty: dirty && !readOnly))
        lastExchange = Date()
        if dirty, !readOnly {
            latest = store?.encodedSnapshot
            pushSoon()
        } else {
            synced = store?.encodedSnapshot
        }
    }

    /// Foreground: push what is pending, otherwise take a newer server copy.
    /// The first activation right after sign-in skips the pull: the bootstrap just did it.
    func appBecameActive() async {
        guard !isClosed else { return }
        if state.dirty {
            _ = await pushNow()
        } else if let lastExchange, Date().timeIntervalSince(lastExchange) < minimumPullInterval {
            return
        } else {
            await pullIfNewer()
        }
    }

    /// Leaving the foreground: no reason to wait out the debounce.
    func appWillResign() {
        if state.dirty { pushSoon() }
    }

    /// Before sign-out: one last push, bounded so the person is never stuck on the button.
    func finalPush(timeout: Duration = .seconds(5)) async {
        guard state.dirty, !isClosed, !isReadOnly else { return }
        pendingPush?.cancel()
        pendingPush = nil
        let push = Task { await self.performPush(timeout: 5) }
        let timer = Task { try? await Task.sleep(for: timeout) }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await push.value }
            group.addTask { await timer.value }
            await group.next()
            group.cancelAll()
        }
        // Out of time: the request must not land after the session is gone.
        push.cancel()
        timer.cancel()
    }

    @discardableResult
    func pushNow() async -> Bool {
        pendingPush?.cancel()
        pendingPush = nil
        if let pushInFlight { return await pushInFlight.value }
        let task = Task { await self.performPush(timeout: 30) }
        pushInFlight = task
        let result = await task.value
        if pushInFlight == task { pushInFlight = nil }
        return result
    }

    func pullIfNewer() async {
        guard let store, !isClosed else { return }
        let remote: RemoteSnapshot?
        do {
            remote = try await client.fetch()
        } catch {
            return
        }
        guard !isClosed else { return }
        lastExchange = Date()
        // Edited while the request was out: ours is newer than anything the server can answer with.
        if state.dirty {
            _ = await pushNow()
            return
        }
        guard let remote else {
            // The server lost its copy (or never got one): ours is the only one left.
            latest = store.encodedSnapshot
            setState(SyncState(version: nil, dirty: true))
            _ = await pushNow()
            return
        }
        if remote.version > (state.version ?? 0) {
            adopt(remote, into: store)
        }
    }

    /// Replaces the store with the server copy without treating that as a local change.
    func adopt(_ remote: RemoteSnapshot, into store: PlanditStore) {
        guard !isClosed, let snapshot = try? SnapshotStore.decode(remote.data) else { return }
        pendingPush?.cancel()
        pendingPush = nil
        isAdopting = true
        store.replace(with: snapshot)
        isAdopting = false
        latest = nil
        synced = try? SnapshotStore.encode(snapshot)
        setState(SyncState(version: remote.version, dirty: false))
    }

    /// Stops every push, queued or in flight. The store's hook is detached by the session.
    func close() {
        isClosed = true
        pendingPush?.cancel()
        pendingPush = nil
        pushInFlight?.cancel()
        pushInFlight = nil
    }

    /// After the account was deleted: close and drop its sync state.
    func forget() {
        close()
        stateStore.remove(userID: userID)
    }

    // MARK: - Internals

    private func schedulePush() {
        pendingPush?.cancel()
        pendingPush = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            _ = await self.pushNow()
        }
    }

    private func pushSoon() {
        pendingPush?.cancel()
        pendingPush = Task { _ = await self.pushNow() }
    }

    private func performPush(timeout: TimeInterval) async -> Bool {
        guard !isClosed, !isReadOnly, let payload = latest ?? store?.encodedSnapshot else { return false }
        do {
            let version = try await client.push(payload, timeout: timeout)
            guard !isClosed, !Task.isCancelled else { return false }
            lastExchange = Date()
            synced = payload
            // A change that landed while the request was out stays dirty.
            let stillCurrent = latest == nil || latest == payload
            if stillCurrent { latest = nil }
            setState(SyncState(version: version, dirty: !stillCurrent))
            if !stillCurrent { schedulePush() }
            return stillCurrent
        } catch {
            return false
        }
    }

    private func setState(_ next: SyncState) {
        guard !isClosed else { return }
        state = next
        stateStore.save(next, for: userID)
    }
}
