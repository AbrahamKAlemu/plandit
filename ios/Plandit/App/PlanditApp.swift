import SwiftUI

@main
struct PlanditApp: App {
    @State private var store = PlanditStore.live()
    @State private var appearance = AppearanceSettings()

    init() {
        Appearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            PlanditRoot(store: store, appearance: appearance)
        }
    }
}

private struct PlanditRoot: View {
    let store: PlanditStore
    let appearance: AppearanceSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environment(store)
            .environment(appearance)
            .tint(Color.emeraldDeep)
            .preferredColorScheme(appearance.mode.colorScheme)
            .accessibilityIdentifier("appearance-\(appearance.mode.rawValue)")
            .task { await store.loadRoutes() }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active { store.ingestPendingShares() }
            }
    }
}
