import XCTest
@testable import Plandit

final class AccountSeedTests: XCTestCase {
    @MainActor private var ownPost: SavedPost {
        SavedPost(
            url: URL(string: "https://www.tiktok.com/@someone/video/7400000000000000500")!,
            platform: .tiktok, savedAt: .now, status: .ready, place: SampleData.levain, estimatedCost: 6
        )
    }

    @MainActor func testEmptyAccountHasNoSampleData() {
        let snapshot = AccountSeed.snapshot(legacy: nil, name: "Sofia")
        XCTAssertTrue(snapshot.saved.isEmpty)
        XCTAssertTrue(snapshot.today.stops.isEmpty)
        XCTAssertTrue(Calendar.current.isDateInToday(snapshot.today.date))
        XCTAssertEqual(snapshot.today.budget, 60)
        XCTAssertTrue(snapshot.pastPlans.isEmpty)
        XCTAssertTrue(snapshot.visited.isEmpty)
        XCTAssertEqual(snapshot.profile, UserProfile(name: "Sofia", school: "", homeBase: "", defaultBudget: 60, travelModes: "Walk + subway"))
    }

    @MainActor func testMigrationKeepsOnlyThePersonsOwnSavesAndDropsPlans() {
        let legacy = StoreSnapshot(
            saved: SampleData.savedPosts + [ownPost],
            today: SampleData.dayPlan,
            profile: SampleData.profile,
            pastPlans: SampleData.pastPlans,
            visited: SampleData.visitedPlaces
        )
        let snapshot = AccountSeed.snapshot(legacy: legacy, name: "Sofia")
        XCTAssertEqual(snapshot.saved.map(\.canonicalURL), [ownPost.canonicalURL])
        XCTAssertTrue(snapshot.today.stops.isEmpty)
        XCTAssertTrue(snapshot.pastPlans.isEmpty)
        XCTAssertTrue(snapshot.visited.isEmpty)
        XCTAssertEqual(snapshot.profile.name, "Sofia", "the untouched sample profile is replaced")
        XCTAssertEqual(snapshot.profile.school, "")
    }

    @MainActor func testMigrationKeepsAChangedProfileUnderTheAccountsName() {
        var profile = SampleData.profile
        profile.homeBase = "Harlem"
        profile.defaultBudget = 40
        let legacy = StoreSnapshot(saved: [], today: SampleData.dayPlan, profile: profile, pastPlans: [], visited: [])

        let named = AccountSeed.snapshot(legacy: legacy, name: "Sofia")
        XCTAssertEqual(named.profile.homeBase, "Harlem")
        XCTAssertEqual(named.profile.defaultBudget, 40)
        XCTAssertEqual(named.profile.name, "Sofia")
        XCTAssertEqual(named.today.budget, 40)

        let unnamed = AccountSeed.snapshot(legacy: legacy, name: "")
        XCTAssertEqual(unnamed.profile.name, "", "the sample name never leaks into a real account")
    }

    @MainActor func testLegacyFileIsTakenOnceAndRenamed() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AccountSeedTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = SnapshotStore(url: directory.appending(path: "plandit-store.json"))
        try legacy.save(StoreSnapshot(saved: [ownPost], today: SampleData.dayPlan, profile: SampleData.profile, pastPlans: [], visited: []))

        let first = AccountSeed.takeLegacySnapshot(from: legacy)
        XCTAssertEqual(first?.saved.count, 1)
        XCTAssertFalse(legacy.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "plandit-store.migrated.json").path()))

        XCTAssertNil(AccountSeed.takeLegacySnapshot(from: legacy), "a second account must not inherit it")
    }

    @MainActor func testStoreURLIsPerAccountAndFilesystemSafe() {
        let directory = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(AccountSeed.storeURL(for: "3f1c-abc", in: directory).lastPathComponent, "plandit-store-3f1c-abc.json")
        XCTAssertEqual(AccountSeed.storeURL(for: "a/b c", in: directory).lastPathComponent, "plandit-store-a_b_c.json")
    }
}
