import SwiftUI

@main
struct PlanditApp: App {
    @State private var store = PlanditStore.sample()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Appearance.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Color.emeraldDeep)
                .task { await store.loadRoutes() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { store.ingestPendingShares() }
                }
        }
    }
}
