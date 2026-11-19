import SwiftUI

@main
struct PlanditApp: App {
    @State private var account: AccountModel
    @State private var appearance = AppearanceSettings()
    @State private var router = SheetRouter()
    @State private var session: AccountSession?

    init() {
        Appearance.configure()
        // A video read can't survive a relaunch: whatever a read left behind goes now, before
        // any store opens or a share is ingested.
        TemporaryMediaStore().removeAbandonedReads()
        _account = State(initialValue: Self.makeAccount())
    }

    /// `-skipAuth` (debug builds only) signs in a fixed local account with sync and events off, so UI
    /// tests run offline. `-resetAuth` forgets any stored session first.
    private static func makeAccount() -> AccountModel {
#if DEBUG
        if CommandLine.arguments.contains("-resetAuth") {
            KeychainAuthSessionStore().clear()
        }
        if CommandLine.arguments.contains("-skipAuth") {
            return .localTest()
        }
#endif
        return .live()
    }

    var body: some Scene {
        WindowGroup {
            AccountGate(account: account, appearance: appearance, router: $router, session: $session)
        }
    }
}

/// loading → splash; signed out → welcome; signed in → the account's store, then the app
/// (after the first-run tutorial, for a brand-new account).
private struct AccountGate: View {
    let account: AccountModel
    let appearance: AppearanceSettings
    @Binding var router: SheetRouter
    @Binding var session: AccountSession?
    /// D-1: decided once when a session opens; finishing the tutorial clears it.
    @State private var showsTutorial = false
    private let tutorial = FirstRunTutorial()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch account.state {
            case .loading:
                SplashScreen()
            case .signedOut, .awaitingConfirmation:
                AuthFlowView()
            case .signedIn(let user):
                if let session, session.userID == user.id {
                    if showsTutorial {
                        TutorialView { finishTutorial(userID: user.id) }
                            .transition(.opacity)
                    } else {
                        PlanditRoot(store: session.store, sync: session.sync, appearance: appearance, router: router)
                    }
                } else {
                    SplashScreen()
                        .task(id: user.id) { await open(user) }
                }
            }
        }
        .environment(account)
        .environment(appearance)
        .tint(Color.emeraldDeep)
        .preferredColorScheme(appearance.mode.colorScheme)
        .task { await account.start() }
        // Shared videos older than a day go even while signed out or in the tutorial, when no
        // store is open to read them (SHR-3).
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { TemporaryMediaStore().removeExpiredFiles() }
        }
        .onChange(of: account.state) { _, state in
            if case .signedIn = state { return }
            close()
        }
    }

    private func open(_ user: AuthUser) async {
        let next: AccountSession
        if account.isLocalTestAccount {
            next = .local(userID: user.id)
        } else {
            next = await AccountSession.bootstrap(user: user, profileName: account.pendingProfileName, api: account.api(for: user.id))
        }
        // Signed out while the fetch was out: don't resurrect the session.
        guard account.currentUser?.id == user.id else {
            next.tearDown()
            return
        }
        account.beforeSignOut = {
            next.store.flush()
            await next.sync?.finalPush()
        }
        account.onAccountDeleted = tutorial.deletionHook(removing: next)
        // Set with the session, in the same update, so the map never flashes first.
        showsTutorial = tutorial.decide(userID: user.id, isNewAccount: next.isNewAccount, launch: .current)
        // A re-bootstrap for the same user must not leave the old session attached to the API.
        session?.tearDown()
        session = next
    }

    /// Skip, or Continue on the last page: remember it for this account on this phone, then the map.
    private func finishTutorial(userID: String) {
        tutorial.recordFinished(userID: userID)
        withAnimation(.easeInOut(duration: 0.25)) { showsTutorial = false }
    }

    /// Signed out (by the person, a revoked session, or deleting the account). The tutorial records
    /// stay, so one cut short by a revoked session still comes back; only deletion forgets them.
    private func close() {
        account.beforeSignOut = nil
        account.onAccountDeleted = nil
        session?.tearDown()
        session = nil
        showsTutorial = false
        router = SheetRouter()
    }
}

private struct PlanditRoot: View {
    let store: PlanditStore
    let sync: SyncCoordinator?
    let appearance: AppearanceSettings
    let router: SheetRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environment(store)
            .environment(appearance)
            .environment(router)
            .tint(Color.emeraldDeep)
            .preferredColorScheme(appearance.mode.colorScheme)
            .accessibilityIdentifier("appearance-\(appearance.mode.rawValue)")
            .task {
                await store.loadRoutes()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    store.rollOverIfNeeded()
                    // Unread shared videos older than a day go first (SHR-3); a share whose video
                    // went this way still arrives, asking for the video again. (AccountGate runs
                    // this too, but not necessarily before the ingest below.)
                    store.removeExpiredTemporaryMedia()
#if DEBUG
                    ShareInbox.seedFromLaunchArguments()
#endif
                    // Coming back from "Share → Plandit": one share opens its post, several open
                    // Saved with them on top; none leaves the app where it was (PRC-1).
                    router.showShares(store.ingestPendingShares())
                    if let sync {
                        Task { await sync.appBecameActive() }
                    }
                case .inactive, .background:
                    store.flush()
                    sync?.appWillResign()
                @unknown default:
                    break
                }
            }
    }
}
