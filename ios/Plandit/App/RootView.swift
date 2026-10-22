import MapKit
import SwiftUI

/// Find My–style shell: a full-screen Manhattan map with a sheet that never dismisses.
/// The tab bar lives inside the sheet, and the sheet's content and map layers switch with the tab.
struct RootView: View {
    @Environment(PlanditStore.self) private var store
    @Environment(AppearanceSettings.self) private var appearance
    @Environment(SheetRouter.self) private var router
    @State private var detent = SheetDetent.launchDetent
    @State private var camera: MapCameraPosition = .camera(Manhattan.overviewCamera)
    @State private var mapSelection: UUID?
    @State private var viewport = MapViewport()
    @State private var location = LocationPermission()

    var body: some View {
        GeometryReader { proxy in
            PlanditMapView(tab: tab, camera: $camera, selection: $mapSelection, onLocate: showUserLocation)
                .onAppear { updateViewport(proxy) }
                .onChange(of: proxy.size) { updateViewport(proxy) }
        }
        .sheet(isPresented: .constant(true)) {
            SheetContainer()
                .environment(store)
                .environment(router)
                .environment(\.isSheetCollapsed, detent == SheetDetent.peek)
                .preferredColorScheme(appearance.mode.colorScheme)
                .presentationDetents(SheetDetent.all, selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(Color.surface)
                .presentationCornerRadius(Radius.sheet)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .onChange(of: router.tab) {
            mapSelection = router.selection(in: tab)
            frameMap()
        }
        .onChange(of: detent) { frameMap() }
        .onChange(of: store.today.stops.count) {
            if tab == .today { frameMap() }
        }
        .onChange(of: router.todayPath) { syncSelectionFromSheet() }
        .onChange(of: router.savedPath) { syncSelectionFromSheet() }
        .onChange(of: mapSelection) { _, id in openDetail(for: id) }
    }

    private var tab: AppTab { router.tab }

    private func showUserLocation() {
        location.requestIfNeeded()
        withAnimation(.smooth(duration: 0.6)) {
            camera = .userLocation(fallback: camera)
        }
    }

    // MARK: - Map ↔ sheet coordination

    private func updateViewport(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        viewport.size = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                               height: proxy.size.height + insets.top + insets.bottom)
        viewport.topInset = insets.top
        frameMap(animated: false)
    }

    /// Tapping a pin opens its detail in the sheet; tapping empty map closes it.
    private func openDetail(for id: UUID?) {
        guard let id else {
            switch tab {
            case .today: if !router.todayPath.isEmpty { router.todayPath = [] }
            case .saved: if !router.savedPath.isEmpty { router.savedPath = [] }
            case .profile: break
            }
            return
        }
        switch tab {
        case .today where store.stop(id: id) != nil && router.todayPath.last != id:
            router.todayPath = [id]
        case .saved where store.post(id: id) != nil && router.savedPath.last != id:
            router.savedPath = [id]
        default:
            break
        }
        if detent == SheetDetent.peek { detent = .medium }
    }

    private func syncSelectionFromSheet() {
        mapSelection = router.selection(in: tab)
        frameMap()
    }

    private func frameMap(animated: Bool = true) {
        guard viewport.size != .zero else { return }
        var framing = viewport
        framing.bottomInset = SheetDetent.coveredHeight(detent, screenHeight: viewport.size.height)

        let coordinates: [CLLocationCoordinate2D]
        if let focused = focusedCoordinate() {
            coordinates = [focused]
        } else {
            switch tab {
            case .today: coordinates = store.today.stops.map(\.place.coordinate)
            case .saved: coordinates = store.saved.filter(\.isMappable).compactMap { $0.place?.coordinate }
            case .profile: coordinates = Manhattan.outline
            }
        }

        let next = MapCameraPosition.camera(framing.camera(fitting: coordinates))
        if animated {
            withAnimation(.smooth(duration: 0.6)) { camera = next }
        } else {
            camera = next
        }
    }

    private func focusedCoordinate() -> CLLocationCoordinate2D? {
        guard let id = router.selection(in: tab) else { return nil }
        switch tab {
        case .today: return store.stop(id: id)?.place.coordinate
        case .saved: return store.post(id: id)?.place?.coordinate
        case .profile: return nil
        }
    }
}

/// The sheet's content: one navigation stack per tab, with the tab bar pinned to the bottom.
private struct SheetContainer: View {
    @Environment(SheetRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        ZStack {
            switch router.tab {
            case .today:
                NavigationStack(path: $router.todayPath) {
                    TodaySheet()
                        .navigationDestination(for: UUID.self) { StopDetailView(stopID: $0) }
                }
                .transition(.opacity)
            case .saved:
                NavigationStack(path: $router.savedPath) {
                    SavedSheet()
                        .navigationDestination(for: UUID.self) { SavedPostDetailView(postID: $0) }
                }
                .transition(.opacity)
            case .profile:
                NavigationStack {
                    ProfileSheet()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: router.tab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlanditTabBar(selection: $router.tab, onPlan: router.startPlanning)
        }
        .sheet(isPresented: $router.isPlanning) {
            PlanBuilderSheet()
        }
    }
}
