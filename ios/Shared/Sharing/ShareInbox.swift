import Foundation

/// The App Group shared by the app and the share extension.
/// Change it here and in project.yml (both entitlements blocks) together.
/// Nonisolated so both the app and the extension can read it from any context (UserDefaults is thread-safe).
nonisolated enum AppGroup {
    static let identifier = "group.com.plandit.app"

    /// Falls back to standard defaults when the entitlement is missing (e.g. unsigned simulator builds),
    /// which keeps the app working but stops shares from reaching it. Shared identity is required
    /// so every `@AppStorage` observer receives the same live change notification.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: identifier) ?? .standard

    /// Shared container for files both targets can read; nil when the entitlement is missing.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// Something shared into Plandit from TikTok, Instagram, Photos, Files or any app's share sheet:
/// a link, or a video the extension copied into `TemporaryMedia/` (named by `videoFileName`).
/// 1.0 queued links only (`url` always set, no `videoFileName`); those entries still decode.
nonisolated struct IncomingShare: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var url: URL?
    var sharedText: String?
    var receivedAt = Date()
    var videoFileName: String?

    init(id: UUID = UUID(), url: URL, sharedText: String? = nil, receivedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.sharedText = sharedText
        self.receivedAt = receivedAt
    }

    init(id: UUID = UUID(), videoFileName: String, receivedAt: Date = Date()) {
        self.id = id
        self.videoFileName = videoFileName
        self.receivedAt = receivedAt
    }
}

/// Hand-off queue: the share extension enqueues, and the app acknowledges only after durable import.
nonisolated enum ShareInbox {
    private static let key = "plandit.pendingShares"

    /// Queues a share and returns what's stored for it. A link that's already waiting isn't queued
    /// twice: the waiting share comes back, and `isNew` is false.
    @discardableResult
    static func enqueue(_ share: IncomingShare) -> (share: IncomingShare, isNew: Bool) {
        withLock {
            var queue = pending()
            if let url = share.url, let waiting = queue.first(where: { $0.url == url }) {
                return (waiting, false)
            }
            queue.append(share)
            write(queue)
            return (share, true)
        }
    }

    static func pending() -> [IncomingShare] {
        guard let data = AppGroup.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IncomingShare].self, from: data)) ?? []
    }

    static func acknowledge(_ id: UUID) {
        withLock {
            write(pending().filter { $0.id != id })
        }
    }

    /// Undo from the share sheet: takes the share back before the app sees it, and deletes the
    /// video it copied. Returns false when the app already took it.
    @discardableResult
    static func remove(_ id: UUID, mediaStore: TemporaryMediaStore?) -> Bool {
        let removed: IncomingShare? = withLock {
            let queue = pending()
            guard let share = queue.first(where: { $0.id == id }) else { return nil }
            write(queue.filter { $0.id != id })
            return share
        }
        guard let removed else { return false }
        if let name = removed.videoFileName, let file = mediaStore?.file(named: name) {
            try? mediaStore?.remove(file)
        }
        return true
    }

    /// The app and the share extension both change the queue, each in its own process, so every
    /// read-change-write holds a file lock in the App Group container. Without the lock file
    /// (it couldn't be opened) the change goes ahead unlocked, as before.
    /// Not reentrant: `body` must not call `enqueue`, `acknowledge` or `remove`.
    private static func withLock<T>(_ body: () -> T) -> T {
        let folder = AppGroup.containerURL ?? FileManager.default.temporaryDirectory
        let descriptor = open(folder.appending(path: "ShareInbox.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        defer { flock(descriptor, LOCK_UN) }
        return body()
    }

    private static func write(_ queue: [IncomingShare]) {
        if queue.isEmpty {
            AppGroup.defaults.removeObject(forKey: key)
        } else {
            AppGroup.defaults.set(try? JSONEncoder().encode(queue), forKey: key)
        }
    }

#if DEBUG
    /// UI tests: `-seedShares 1` (up to 3) queues that many TikTok shares once per launch, as if
    /// they'd come through the share sheet while Plandit was closed.
    nonisolated(unsafe) private static var didSeed = false

    static func seedFromLaunchArguments(_ arguments: [String] = CommandLine.arguments) {
        guard !didSeed, let index = arguments.firstIndex(of: "-seedShares"), index + 1 < arguments.count,
              let count = Int(arguments[index + 1]) else { return }
        didSeed = true
        let samples: [(String, String)] = [
            ("https://www.tiktok.com/@nycbites/video/7400000000000000201", "The cookies at Levain Bakery are worth the line"),
            ("https://www.tiktok.com/@cheapeatsnyc/video/7400000000000000202", "Best tacos in Chelsea Market"),
            ("https://www.tiktok.com/@parkdays/video/7400000000000000203", "Sunset walk on the High Line"),
        ]
        for (url, text) in samples.prefix(max(0, min(count, samples.count))) {
            enqueue(IncomingShare(url: URL(string: url)!, sharedText: "\(text) \(url)"))
        }
    }
#endif
}
