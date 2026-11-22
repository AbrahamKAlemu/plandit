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
    /// The sheet's horizontal extent on screen. On iPad it's a panel narrower than the screen.
    @State private var sheetColumns: ClosedRange<CGFloat>?
    @State private var location = LocationPermission()
    /// The sheet rises once the map has mostly faded in from the splash, not over the logo. After
    /// that it never closes: the binding ignores dismissal, as `.constant(true)` did.
    @State private var isSheetShown = false

    var body: some View {
        GeometryReader { proxy in
            PlanditMapView(tab: tab, camera: $camera, selection: $mapSelection, onLocate: showUserLocation)
                .onAppear { updateViewport(proxy) }
                .onChange(of: proxy.size) { updateViewport(proxy) }
        }
        .sheet(isPresented: Binding(get: { isSheetShown }, set: { _ in })) {
            SheetContainer()
                .onGeometryChange(for: ClosedRange<CGFloat>.self) { proxy in
                    let frame = proxy.frame(in: .global)
                    return frame.minX.rounded()...frame.maxX.rounded()
                } action: { columns in
                    sheetColumns = columns
                }
                .environment(store)
                .environment(router)
                .preferredColorScheme(appearance.mode.colorScheme)
                .presentationDetents(SheetDetent.all, selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(Color.surface)
                .presentationCornerRadius(Radius.sheet)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            isSheetShown = true
        }
        .onChange(of: router.tab) {
            mapSelection = router.selection(in: tab)
            frameMap()
        }
        .onChange(of: detent) { frameMap() }
        // New shares rise from the peek to half height so they're seen (PRC-1).
        .onChange(of: router.sharesShown) {
            if detent == SheetDetent.peek { detent = .medium }
        }
        .onChange(of: sheetColumns) { frameMap(animated: false) }
        .onChange(of: store.today.stops.count) {
            if tab == .today { frameMap() }
        }
        .onChange(of: store.visited.count) {
            if tab == .profile { frameMap() }
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
        // At full height an iPad panel covers the middle of the map, so content goes beside it.
        let framing = viewport.uncovered(
            coveredHeight: SheetDetent.coveredHeight(detent, screenHeight: viewport.size.height),
            fullHeightPanel: detent == .large ? sheetColumns : nil
        )

        let coordinates: [CLLocationCoordinate2D]
        if let focused = focusedCoordinate() {
            coordinates = [focused]
        } else {
            switch tab {
            case .today: coordinates = store.today.stops.map(\.place.coordinate)
            case .saved: coordinates = store.saved.filter(\.isMappable).compactMap { $0.place?.coordinate }
            case .profile: coordinates = Manhattan.profileFocus(visited: store.visited.map(\.coordinate))
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

/// The sheet's content: one navigation stack per tab, with the tab bar floating at the bottom.
///
/// The undo and tab bars float over the stacks, so content scrolls on under them. Their measured
/// height goes down as `floatingBarsHeight`, and every screen in the stacks reserves it with
/// `clearsFloatingBars()` so its end still clears them (W-1). It has to be on each screen, roots
/// and pushed ones: each `NavigationStack` hosts its screens in their own UIKit controllers, and
/// inside this sheet those controllers take their safe area from the sheet, not from SwiftUI. A
/// `safeAreaInset` or `safeAreaPadding` here, outside the stacks, is ignored by every scroll view
/// in them, roots included. The environment does reach every screen, so the height goes that way.
private struct SheetContainer: View {
    @Environment(SheetRouter.self) private var router
    @Environment(PlanditStore.self) private var store
    /// While the keyboard is up the bars step aside and their space is given back, so a screen
    /// reaches down to the keyboard and a field's button (Search, Save) isn't hidden behind them.
    @State private var isKeyboardUp = false
    /// The undo and tab bars' height, kept clear at the foot of every screen.
    @State private var barsHeight: CGFloat = 0
    /// The sheet's height, measured as it moves. Nil until the first layout.
    @State private var sheetHeight: CGFloat?

    /// How much of each screen's body shows (`hiddenWhenSheetCollapsed`). Always all of it while
    /// typing: the keyboard shortens the measured height, not the sheet.
    private var reveal: Double {
        guard let sheetHeight, !isKeyboardUp else { return 1 }
        return SheetDetent.reveal(sheetHeight: sheetHeight)
    }

    var body: some View {
        @Bindable var router = router
        stacks
            .environment(\.floatingBarsHeight, isKeyboardUp ? 0 : barsHeight)
            .environment(\.sheetReveal, reveal)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
            .overlay(alignment: .bottom) {
                // The undo bar floats just above the tab bar.
                if !isKeyboardUp {
                    VStack(spacing: Space.xs) {
                        UndoBar()
                        PlanditTabBar(selection: $router.tab, onPlan: { router.startPlanning() })
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barsHeight = $0 }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardUp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardUp = false
            }
            // A place added to Saved, by an exact match or a pick, from the list or a post (PRC-7).
            // Here, always on screen, rather than under a pushed post, so each one plays exactly once.
            .sensoryFeedback(.success, trigger: store.placesAdded)
            .sheet(isPresented: $router.isPlanning) {
                PlanBuilderSheet()
            }
    }

    private var stacks: some View {
        @Bindable var router = router
        return ZStack {
            switch router.tab {
            case .today:
                NavigationStack(path: $router.todayPath) {
                    TodaySheet()
                        .clearsFloatingBars()
                        .navigationDestination(for: UUID.self) { StopDetailView(stopID: $0).clearsFloatingBars() }
                }
                .transition(.opacity)
            case .saved:
                NavigationStack(path: $router.savedPath) {
                    SavedSheet()
                        .clearsFloatingBars()
                        .navigationDestination(for: UUID.self) { SavedPostDetailView(postID: $0).clearsFloatingBars() }
                }
                .transition(.opacity)
            case .profile:
                NavigationStack {
                    ProfileSheet()
                        .clearsFloatingBars()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: router.tab)
    }
}
