import SwiftUI

@main
struct PlanditApp: App {
    @State private var account: AccountModel
    @State private var appearance = AppearanceSettings()
    @State private var router = SheetRouter()
    @State private var session: AccountSession?

    init() {
        Appearance.configure()
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

/// loading → splash; signed out → welcome; signed in → the account's store, then the app.
private struct AccountGate: View {
    let account: AccountModel
    let appearance: AppearanceSettings
    @Binding var router: SheetRouter
    @Binding var session: AccountSession?

    var body: some View {
        Group {
            switch account.state {
            case .loading:
                SplashScreen()
            case .signedOut, .awaitingConfirmation:
                AuthFlowView()
            case .signedIn(let user):
                if let session, session.userID == user.id {
                    PlanditRoot(store: session.store, sync: session.sync, appearance: appearance, router: router)
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
        account.onAccountDeleted = { _ in next.removeLocalData() }
        // A re-bootstrap for the same user must not leave the old session attached to the API.
        session?.tearDown()
        session = next
    }

    private func close() {
        account.beforeSignOut = nil
        account.onAccountDeleted = nil
        session?.tearDown()
        session = nil
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
                store.removeExpiredTemporaryMedia()
                await store.loadRoutes()
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active:
                    store.rollOverIfNeeded()
                    // Coming back from "Share → Plandit": take the user straight to what they just saved.
                    let incoming = store.ingestPendingShares()
                    if incoming.count == 1, let id = incoming.first {
                        router.showPost(id)
                    } else if !incoming.isEmpty {
                        router.show(.saved)
                    }
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
