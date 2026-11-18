import XCTest
@testable import Plandit

/// D-1: a brand-new account sees the tutorial once on this phone; an account with data never does.
final class FirstRunTutorialTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FirstRunTutorialTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor private func tutorial() -> FirstRunTutorial {
        FirstRunTutorial(defaults: defaults)
    }

    /// The gate's call when a session opens, with these debug launch arguments.
    @MainActor private func opens(_ userID: String = "user-1", isNewAccount: Bool, _ arguments: [String] = []) -> Bool {
        tutorial().decide(userID: userID, isNewAccount: isNewAccount, launch: TutorialLaunchOptions(arguments: ["Plandit"] + arguments))
    }

    // MARK: - Decision

    @MainActor func testBrandNewAccountSeesIt() {
        XCTAssertTrue(opens(isNewAccount: true))
    }

    @MainActor func testExistingAccountNeverSeesIt() {
        XCTAssertFalse(opens(isNewAccount: false), "including on a new phone, where nothing is recorded")
    }

    @MainActor func testFinishedNeverShowsAgainEvenForANewAccount() {
        tutorial().recordFinished(userID: "user-1")
        XCTAssertFalse(opens(isNewAccount: true))
    }

    @MainActor func testFinishingRecordsItSoARelaunchDoesNotRepeatIt() {
        XCTAssertTrue(opens(isNewAccount: true))
        tutorial().recordFinished(userID: "user-1")

        XCTAssertTrue(tutorial().hasFinished(userID: "user-1"))
        XCTAssertFalse(opens(isNewAccount: false))
        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth", "-showTutorial"]), "the UI test's relaunch")
    }

    @MainActor func testTheRecordIsPerUser() {
        tutorial().recordFinished(userID: "user-1")
        XCTAssertTrue(opens("user-2", isNewAccount: true), "another account on this phone still gets it")
        XCTAssertNotEqual(FirstRunTutorial.finishedKey(for: "user-1"), FirstRunTutorial.finishedKey(for: "user-2"))
        XCTAssertTrue(FirstRunTutorial.finishedKey(for: "user-1").contains("user-1"))
    }

    @MainActor func testForgetClearsBothRecordsForThatUserOnly() {
        for userID in ["user-1", "user-2"] {
            XCTAssertTrue(opens(userID, isNewAccount: true))
            tutorial().recordFinished(userID: userID)
        }
        tutorial().forget(userID: "user-1")

        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
        XCTAssertTrue(tutorial().hasStarted(userID: "user-2"))
        XCTAssertTrue(tutorial().hasFinished(userID: "user-2"))
    }

    // MARK: - Interrupted

    @MainActor func testShowingANewAccountMarksItStarted() {
        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
        XCTAssertTrue(opens(isNewAccount: true))
        XCTAssertTrue(tutorial().hasStarted(userID: "user-1"))
        XCTAssertEqual(FirstRunTutorial.startedKey(for: "user-1"), "plandit.tutorialStarted.user-1")
    }

    /// They leave on page 1 to save a place from TikTok and iOS closes Plandit. The next bootstrap
    /// finds their file, so it is no longer a new account, but the tutorial comes back until finished.
    @MainActor func testAnInterruptedTutorialComesBackUntilFinished() {
        XCTAssertTrue(opens(isNewAccount: true))

        XCTAssertTrue(opens(isNewAccount: false), "started but not finished")
        XCTAssertTrue(opens(isNewAccount: false), "every launch until it is finished")

        tutorial().recordFinished(userID: "user-1")
        XCTAssertFalse(opens(isNewAccount: false))
    }

    @MainActor func testExistingAccountIsNeverMarkedStarted() {
        XCTAssertFalse(opens(isNewAccount: false))
        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
    }

    /// UI tests that stop mid-tutorial must not leak it into the other UI tests, which all launch
    /// the same `-skipAuth` account without `-showTutorial`.
    @MainActor func testShowTutorialDoesNotMarkItStarted() {
        XCTAssertTrue(opens(isNewAccount: false, ["-skipAuth", "-showTutorial"]))
        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth"]))
    }

    @MainActor func testResetTutorialClearsAStartedTutorial() {
        XCTAssertTrue(opens(isNewAccount: true))

        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth", "-resetTutorial"]))
        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
    }

    // MARK: - Account deleted

    @MainActor func testTheDeletionHookRemovesLocalDataAndBothRecords() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FirstRunTutorialTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = AuthUser(id: "user-1", email: "sofia@example.edu", fullName: "Sofia", provider: "email")
        let session = await AccountSession.bootstrap(
            user: user, profileName: nil, api: nil, directory: directory,
            legacyStore: SnapshotStore(url: directory.appending(path: "missing-legacy.json"))
        )
        let file = AccountSeed.storeURL(for: "user-1", in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path()))
        for userID in ["user-1", "user-2"] {
            XCTAssertTrue(opens(userID, isNewAccount: true))
            tutorial().recordFinished(userID: userID)
        }

        let hook = tutorial().deletionHook(removing: session)
        hook("user-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path()))
        XCTAssertFalse(tutorial().hasStarted(userID: "user-1"))
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
        XCTAssertTrue(tutorial().hasFinished(userID: "user-2"), "another account on this phone keeps its record")
    }

    @MainActor func testShowTutorialForcesItForAnExistingAccount() {
        XCTAssertTrue(opens(isNewAccount: false, ["-skipAuth", "-showTutorial"]))
    }

    @MainActor func testResetTutorialClearsTheRecord() {
        tutorial().recordFinished(userID: "user-1")

        XCTAssertTrue(opens(isNewAccount: false, ["-skipAuth", "-resetTutorial", "-showTutorial"]))
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
    }

    @MainActor func testResetTutorialAloneDoesNotShowIt() {
        tutorial().recordFinished(userID: "user-1")

        XCTAssertFalse(opens(isNewAccount: false, ["-skipAuth", "-resetTutorial"]), "-skipAuth's account is not new")
        XCTAssertFalse(tutorial().hasFinished(userID: "user-1"))
    }

    // MARK: - Debug launch arguments

    func testSkipAuthAloneChangesNothing() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth"])
        XCTAssertFalse(options.countsAsNewAccount)
        XCTAssertFalse(options.resetsFinished)
    }

    func testShowTutorialCountsTheSessionAsNew() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth", "-showTutorial"])
        XCTAssertTrue(options.countsAsNewAccount)
        XCTAssertFalse(options.resetsFinished)
    }

    func testResetTutorialForgetsTheRecord() {
        let options = TutorialLaunchOptions(arguments: ["Plandit", "-skipAuth", "-resetTutorial", "-showTutorial"])
        XCTAssertTrue(options.countsAsNewAccount)
        XCTAssertTrue(options.resetsFinished)
    }

    // MARK: - Pages

    func testThreePagesInOrder() {
        XCTAssertEqual(TutorialPage.allCases.map(\.number), [1, 2, 3])
        XCTAssertEqual(TutorialPage.allCases.map(\.pageLabel), ["Page 1 of 3", "Page 2 of 3", "Page 3 of 3"])
        XCTAssertEqual(TutorialPage.share.next, .shape)
        XCTAssertEqual(TutorialPage.shape.next, .plan)
        XCTAssertNil(TutorialPage.plan.next, "Continue on the last page finishes")
    }
}
