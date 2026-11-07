import Foundation

/// What a signed-in account starts with. Real accounts never get sample data.
enum AccountSeed {
    /// The file name for one account's store, next to the pre-account `plandit-store.json`.
    static func storeURL(for userID: String, in directory: URL) -> URL {
        let safe = userID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        return directory.appending(path: "plandit-store-\(String(safe)).json")
    }

    /// Default profile for a brand-new account.
    static func newProfile(name: String) -> UserProfile {
        UserProfile(name: name, school: "", homeBase: "", defaultBudget: 60, travelModes: "Walk + subway")
    }

    /// Empty account, or the pre-account data that is worth keeping: the posts the person saved
    /// themselves (sample posts dropped) and their profile if they changed it. Plans never carry over.
    static func snapshot(legacy: StoreSnapshot?, name: String, now: Date = .now) -> StoreSnapshot {
        var profile = newProfile(name: name)
        var saved: [SavedPost] = []
        if let legacy {
            saved = ownPosts(in: legacy)
            if legacy.profile != SampleData.profile {
                profile = legacy.profile
                if !name.isEmpty || profile.name == SampleData.profile.name {
                    profile.name = name
                }
            }
        }
        return StoreSnapshot(
            saved: saved,
            today: .empty(for: now, budget: profile.defaultBudget),
            profile: profile,
            pastPlans: [],
            visited: []
        )
    }

    /// The posts in the pre-account file that the person saved themselves.
    static func ownPosts(in legacy: StoreSnapshot) -> [SavedPost] {
        let sampleURLs = Set(SampleData.savedPosts.map(\.canonicalURL))
        return legacy.saved.filter { !sampleURLs.contains($0.canonicalURL) }
    }

    /// Adds the posts the snapshot does not already have (by canonical URL), keeping newest first.
    static func merging(_ posts: [SavedPost], into snapshot: StoreSnapshot) -> (snapshot: StoreSnapshot, added: Int) {
        var known = Set(snapshot.saved.map(\.canonicalURL))
        var added: [SavedPost] = []
        for post in posts where known.insert(post.canonicalURL).inserted {
            added.append(post)
        }
        guard !added.isEmpty else { return (snapshot, 0) }
        var merged = snapshot
        merged.saved = (snapshot.saved + added).sorted { $0.savedAt > $1.savedAt }
        return (merged, added.count)
    }

    /// The pre-account file's content, if it has not been migrated yet. Does not touch the file.
    static func legacySnapshot(in store: SnapshotStore) -> StoreSnapshot? {
        guard FileManager.default.fileExists(atPath: store.url.path()) else { return nil }
        return store.load()
    }

    /// Renames the pre-account file so a second account never inherits it.
    static func retireLegacyFile(in store: SnapshotStore) {
        guard FileManager.default.fileExists(atPath: store.url.path()) else { return }
        let migrated = store.url.deletingPathExtension().appendingPathExtension("migrated.json")
        try? FileManager.default.removeItem(at: migrated)
        try? FileManager.default.moveItem(at: store.url, to: migrated)
    }

    /// Reads the pre-account file once and renames it.
    static func takeLegacySnapshot(from store: SnapshotStore) -> StoreSnapshot? {
        let snapshot = legacySnapshot(in: store)
        retireLegacyFile(in: store)
        return snapshot
    }
}
