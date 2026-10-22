import MapKit
import SwiftUI

/// The full-screen Manhattan map behind the sheet. Its layers change with the selected tab.
struct PlanditMapView: View {
    let tab: AppTab
    @Binding var camera: MapCameraPosition
    @Binding var selection: UUID?
    /// Called from the locate button; location permission is requested then, not at launch.
    let onLocate: () -> Void
    @Environment(PlanditStore.self) private var store
    @Namespace private var mapScope

    var body: some View {
        ZStack(alignment: .topTrailing) {
            map.ignoresSafeArea()

            VStack(spacing: Space.xs) {
                CircleIconButton(.navigation, label: "Show my location", action: onLocate)
                MapCompass(scope: mapScope)
            }
            .padding(.trailing, Space.md)
            .padding(.top, Space.xs)
        }
        .mapScope(mapScope)
    }

    private var map: some View {
        Map(position: $camera, bounds: Manhattan.cameraBounds, selection: $selection, scope: mapScope) {
            UserAnnotation()

            if tab == .today {
                ForEach(store.today.legs) { leg in
                    let state = store.today.state(of: leg)
                    MapPolyline(coordinates: store.path(for: leg))
                        .stroke(state.color.opacity(state.opacity), style: StrokeStyle(
                            lineWidth: state.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: leg.mode == .walk ? [] : [1, 9] // dotted = transit
                        ))
                }
                ForEach(Array(store.today.stops.enumerated()), id: \.element.id) { index, stop in
                    Annotation(stop.place.name, coordinate: stop.place.coordinate, anchor: .center) {
                        StopPin(number: index + 1, status: stop.status, isSelected: selection == stop.id)
                    }
                    .tag(stop.id)
                    .annotationTitles(.hidden)
                }
            }

            if tab == .saved {
                ForEach(store.saved.filter(\.isMappable)) { post in
                    if let place = post.place {
                        Annotation(place.name, coordinate: place.coordinate, anchor: .center) {
                            SavedPin(category: place.category, isSelected: selection == post.id)
                        }
                        .tag(post.id)
                        .annotationTitles(.hidden)
                    }
                }
            }

            if tab == .profile {
                ForEach(store.visited) { place in
                    Annotation(place.name, coordinate: place.coordinate, anchor: .center) {
                        VisitedDot()
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {} // custom controls above: Lucide icons only
    }
}
