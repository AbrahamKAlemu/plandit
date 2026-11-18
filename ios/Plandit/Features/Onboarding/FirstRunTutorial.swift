import Foundation

/// D-1: whether a signed-in session starts with the first-run tutorial, and the record on this
/// phone that it was finished.
///
/// Only a brand-new account sees it (`AccountSession.isNewAccount`: nothing on the server or the
/// phone), so an existing account never does, even on a new phone. Finishing it (Skip, or Continue
/// on the last page) is recorded per user id, so a relaunch never repeats it.
struct FirstRunTutorial {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func finishedKey(for userID: String) -> String {
        "plandit.tutorialFinished.\(userID)"
    }

    /// The gate's whole decision, made once when a session opens: `-resetTutorial` first, then a
    /// brand-new account (or one `-showTutorial` counts as new) that hasn't finished it here.
    func decide(userID: String, isNewAccount: Bool, launch: TutorialLaunchOptions) -> Bool {
        if launch.resetsFinished { forget(userID: userID) }
        return (isNewAccount || launch.countsAsNewAccount) && !hasFinished(userID: userID)
    }

    func hasFinished(userID: String) -> Bool {
        defaults.bool(forKey: Self.finishedKey(for: userID))
    }

    func recordFinished(userID: String) {
        defaults.set(true, forKey: Self.finishedKey(for: userID))
    }

    /// After the account is deleted, or for `-resetTutorial`.
    func forget(userID: String) {
        defaults.removeObject(forKey: Self.finishedKey(for: userID))
    }
}

/// Debug launch arguments for UI tests; release builds ignore them.
/// `-showTutorial` counts the signed-in session as a brand-new account, so the real decision runs,
/// including the finished record. `-resetTutorial` forgets that record first. `-skipAuth` alone
/// never shows the tutorial: its local account is not new.
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
