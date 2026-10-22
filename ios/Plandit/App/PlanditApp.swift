import SwiftUI

@main
struct PlanditApp: App {
    @State private var store = PlanditStore.load()
    @State private var appearance = AppearanceSettings()
    @State private var router = SheetRouter()

    init() {
        Appearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            PlanditRoot(store: store, appearance: appearance, router: router)
        }
    }
}

private struct PlanditRoot: View {
    let store: PlanditStore
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
            .task { await store.loadRoutes() }
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
                case .inactive, .background:
                    store.flush()
                @unknown default:
                    break
                }
            }
    }
}
