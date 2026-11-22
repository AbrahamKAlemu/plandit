import XCTest
@testable import Plandit

/// The group plan store belongs to the signed-in account: built with the session, filed into its
/// recent plans, and closed with it. REM-4 at the session: signing out or deleting the account
/// deletes the group cache and leaves a closed store that writes nothing more.
@MainActor final class GroupPlanSessionTests: XCTestCase {
    private struct NoExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    private var directory: URL!
    private let user = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "group-plan-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private var cacheURL: URL { GroupPlanStore.cacheURL(for: user.id, in: directory) }

    private var cacheExists: Bool { FileManager.default.fileExists(atPath: cacheURL.path(percentEncoded: false)) }

    /// Today in New York, so the group's day isn't over and an edit to it would be queued.
    private var today: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return GroupPlanDay.string(for: Date(), calendar: calendar)
    }

    private func plan() -> DayPlan {
        var plan = SampleData.dayPlan
        for stop in plan.stops.indices { plan.stops[stop].status = .upcoming }
        return plan
    }

    /// Leaves this account's group cache on the phone, as an earlier sign-in would: one group.
    private func cacheOneGroup(for userID: String? = nil) async -> UUID {
        let server = FakeGroupPlanServer()
        let id = await server.seedGroup(plan: plan(), date: today, organizer: "Maya", others: ["Jordan"])
        let earlier = GroupPlanStore(userID: userID ?? user.id, server: server, directory: directory)
        await earlier.refreshList()
        XCTAssertNotNil(earlier.group(id)?.plan, "cached")
        earlier.close()
        return id
    }

    /// The server answers "no snapshot yet", accepts the seed, and nothing else.
    private func emptyServer() -> FakeTransport {
        FakeTransport { request in
            switch request.httpMethod {
            case "GET": return (404, TestJSON.object(["detail": "No snapshot yet."]))
            case "PUT": return (200, TestJSON.object(["version": 1]))
            default: return (500, Data())
            }
        }
    }

    private func bootstrap(_ transport: FakeTransport?) async -> AccountSession {
        let api = transport.map {
            PlanditAPIClient(baseURL: TestJSON.configuration.apiBaseURL, userID: user.id, tokenProvider: FakeTokenProvider(), transport: $0)
        }
        let session = await AccountSession.bootstrap(
            user: user, profileName: nil, api: api, directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json")), extractor: NoExtractor()
        )
        addTeardownBlock { @MainActor in session.tearDown() }
        return session
    }

    /// A removal of the group's first stop: queued on an open store, refused by a closed one.
    private func anEdit(_ groups: GroupPlanStore, _ id: UUID) throws -> PlanEdit {
        let shown = try XCTUnwrap(groups.group(id)?.plan)
        return try XCTUnwrap(PlanEdit.removing(shown.stops[0].id, in: shown, travel: .walkAndTransit))
    }

    /// Closed: no recent plans to file into, no edits taken, and the cache isn't written again.
    private func assertClosed(_ groups: GroupPlanStore, _ id: UUID, cacheKept: Bool,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(groups.history, "detached from the account's store", file: file, line: line)
        XCTAssertEqual(groups.apply(try anEdit(groups, id), to: id), .unavailable, "no edits after closing", file: file, line: line)
        groups.rollOverIfNeeded()
        XCTAssertEqual(cacheExists, cacheKept, cacheKept ? "cache kept" : "cache deleted, and not written again", file: file, line: line)
    }

    // MARK: - Building

    func testASignedInSessionHasGroupPlansFiledIntoItsOwnRecentPlans() async throws {
        let id = await cacheOneGroup()

        let session = await bootstrap(emptyServer())

        let groups = try XCTUnwrap(session.groups)
        XCTAssertTrue(groups.history === session.store, "a group day is filed into this account's recent plans")
        XCTAssertNotNil(groups.group(id), "the account's cache, from its own file")
    }

    /// REM-5 at the session: another account's cache on the same phone isn't read.
    func testREM5_ASessionDoesntReadAnotherAccountsGroups() async throws {
        let theirs = await cacheOneGroup(for: "user-2")

        let session = await bootstrap(emptyServer())

        XCTAssertNil(try XCTUnwrap(session.groups).group(theirs))
    }

    func testALocalOnlySessionHasNoGroupPlans() async {
        let session = await bootstrap(nil)
        XCTAssertNil(session.groups)
    }

    // MARK: - REM-4

    /// REM-4: account deletion.
    func testREM4_DeletingTheAccountDeletesTheGroupCacheAndClosesTheStore() async throws {
        let id = await cacheOneGroup()
        let session = await bootstrap(emptyServer())
        let groups = try XCTUnwrap(session.groups)
        XCTAssertTrue(cacheExists)

        session.removeLocalData()

        try assertClosed(groups, id, cacheKept: false)
    }

    /// REM-4: sign-out.
    func testREM4_SigningOutDeletesTheGroupCacheAndClosesTheStore() async throws {
        let id = await cacheOneGroup()
        let session = await bootstrap(emptyServer())
        let groups = try XCTUnwrap(session.groups)

        session.forgetGroupPlans()

        try assertClosed(groups, id, cacheKept: false)
    }

    /// Replaced by a new session for the same account (a second bootstrap): the cache stays for it.
    func testTearingDownClosesTheStoreButKeepsTheCache() async throws {
        let id = await cacheOneGroup()
        let session = await bootstrap(emptyServer())
        let groups = try XCTUnwrap(session.groups)

        session.tearDown()

        try assertClosed(groups, id, cacheKept: true)
    }

    // MARK: - -fakeGroupPlans

    /// The local test account gets the fake server's groups, starting from its seed each launch:
    /// a cache an earlier launch left behind isn't shown.
    func testFakeGroupPlansStartFromTheSeedEachLaunch() async throws {
        let stale = await cacheOneGroup()
        let session = await bootstrap(nil)

        await session.attachFakeGroupPlans(["Plandit", "-skipAuth", "-fakeGroupPlans"], directory: directory)

        let groups = try XCTUnwrap(session.groups)
        XCTAssertTrue(groups.history === session.store)
        XCTAssertEqual(groups.groups.map(\.id), [FakeGroupPlanServer.seededGroupID])
        XCTAssertNil(groups.group(stale))
        let joinable = await groups.preview(token: FakeGroupPlanServer.joinableToken)
        XCTAssertEqual(try joinable.get().organizerName, "Jordan")
    }

    func testWithoutTheArgumentThereAreNoFakeGroupPlans() async {
        let session = await bootstrap(nil)

        await session.attachFakeGroupPlans(["Plandit", "-skipAuth"], directory: directory)

        XCTAssertNil(session.groups)
    }
}
