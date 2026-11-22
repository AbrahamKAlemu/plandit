import Foundation

/// Everything needed to bring the app back exactly as the user left it.
/// Also the account's cloud copy: the server stores this JSON unchanged.
struct StoreSnapshot: Codable {
    var saved: [SavedPost]
    var today: DayPlan
    var profile: UserProfile
    var pastPlans: [PastPlan]
    var visited: [Place]
    /// Today's plan shared as a link, if it is. Older files and builds have none.
    var sharedLink: SharedLink? = nil
    /// The "Ask friends what works" link, if there is one. Older files and builds have none.
    var planRequest: PlanRequestLink? = nil
}

/// One JSON file in the App Group container (so the share extension could read it too),
/// or Application Support when the build is unsigned and has no container.
struct SnapshotStore {
    let url: URL

    /// Where every store file lives.
    static let directory: URL =
        AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// The pre-account file. Signed-in accounts use `plandit-store-<user-id>.json` instead.
    static let `default` = SnapshotStore(url: directory.appending(path: "plandit-store.json"))

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The one JSON shape for the file and the cloud copy: camelCase keys, ISO 8601 dates, sorted keys.
    static func encode(_ snapshot: StoreSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> StoreSnapshot {
        try decoder.decode(StoreSnapshot.self, from: data)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path()) }

    /// nil on first launch or if the file can't be read; the caller falls back to sample data.
    func load() -> StoreSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decode(data)
    }

    func save(_ snapshot: StoreSnapshot) throws {
        let data = try Self.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func reset() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: doneTodayURL)
    }

    // MARK: - Places done today

    /// Beside the snapshot and never synced: `plandit-store.done-today.json`.
    var doneTodayURL: URL {
        url.deletingPathExtension().appendingPathExtension("done-today.json")
    }

    func loadDoneToday() -> DoneToday? {
        guard let data = try? Data(contentsOf: doneTodayURL) else { return nil }
        return try? Self.decoder.decode(DoneToday.self, from: data)
    }

    func saveDoneToday(_ doneToday: DoneToday) throws {
        let data = try Self.encoder.encode(doneToday)
        try FileManager.default.createDirectory(at: doneTodayURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: doneTodayURL, options: .atomic)
    }
}

/// The saved posts checked off ("Done here") on one local date, kept on this phone only so a place
/// done today and then taken out of the plan isn't suggested again today (SP-9).
struct DoneToday: Codable, Equatable {
    /// The local date, "2026-11-21".
    var day: String
    var postIDs: Set<UUID>

    /// Always Gregorian, in the phone's time zone, whatever calendar the phone is set to.
    static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
