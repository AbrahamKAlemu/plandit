import Foundation

/// D-1: whether a signed-in session starts with the first-run tutorial, and what this phone
/// remembers about it, per user id.
///
/// Only a brand-new account starts it (`AccountSession.isNewAccount`: nothing on the server or the
/// phone), so an existing account never does, even on a new phone. Starting it is recorded, so a
/// tutorial cut short comes back on the next launch, when bootstrap no longer says new. Finishing
/// it (Skip on any page, or Continue on the last) is recorded too, and then it never shows again.
struct FirstRunTutorial {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func startedKey(for userID: String) -> String {
        "plandit.tutorialStarted.\(userID)"
    }

    static func finishedKey(for userID: String) -> String {
        "plandit.tutorialFinished.\(userID)"
    }

    /// The gate's whole decision, made once when a session opens: `-resetTutorial` first, then
    /// show it to a brand-new account, or one that started it and hasn't finished. `-showTutorial`
    /// forces it without marking it started.
    func decide(userID: String, isNewAccount: Bool, launch: TutorialLaunchOptions) -> Bool {
        if launch.resetsFinished { forget(userID: userID) }
        guard !hasFinished(userID: userID) else { return false }
        if isNewAccount { defaults.set(true, forKey: Self.startedKey(for: userID)) }
        return hasStarted(userID: userID) || launch.countsAsNewAccount
    }

    func hasStarted(userID: String) -> Bool {
        defaults.bool(forKey: Self.startedKey(for: userID))
    }

    func hasFinished(userID: String) -> Bool {
        defaults.bool(forKey: Self.finishedKey(for: userID))
    }

    func recordFinished(userID: String) {
        defaults.set(true, forKey: Self.finishedKey(for: userID))
    }

    /// Both records, after the account is deleted and for `-resetTutorial`. Signing out keeps them.
    func forget(userID: String) {
        defaults.removeObject(forKey: Self.startedKey(for: userID))
        defaults.removeObject(forKey: Self.finishedKey(for: userID))
    }

    /// `AccountModel.onAccountDeleted` for this session: once the server confirms the account is
    /// gone, its data on this phone goes, and so do its tutorial records.
    func deletionHook(removing session: AccountSession) -> (String) -> Void {
        { userID in
            session.removeLocalData()
            forget(userID: userID)
        }
    }
}

/// Debug launch arguments for UI tests; release builds ignore them.
/// `-showTutorial` counts the signed-in session as a brand-new account, so the real decision runs,
/// including the finished record, but it doesn't mark the tutorial started: a UI test that stops
/// mid-tutorial can't leak it into the others. `-resetTutorial` forgets both records first.
/// `-skipAuth` alone never shows the tutorial: its local account is not new.
nonisolated struct TutorialLaunchOptions: Equatable {
    var countsAsNewAccount = false
    var resetsFinished = false

    init(arguments: [String]) {
#if DEBUG
        countsAsNewAccount = arguments.contains("-showTutorial")
        resetsFinished = arguments.contains("-resetTutorial")
#endif
    }

    static var current: TutorialLaunchOptions {
        TutorialLaunchOptions(arguments: CommandLine.arguments)
    }
}
