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
        // Read the routes here, in the view's body, so the map redraws when street paths arrive.
        // (Reads inside Map's content builder alone don't always trigger an update.)
        let lines = tab == .today ? store.today.legs.map { RouteLine(leg: $0, plan: store.today, path: store.path(for: $0)) } : []
        return Map(position: $camera, bounds: Manhattan.cameraBounds, selection: $selection, scope: mapScope) {
            UserAnnotation()

            if tab == .today {
                ForEach(lines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.state.color.opacity(line.state.opacity), style: StrokeStyle(
                            lineWidth: line.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: line.mode.dash // solid walk, dotted transit, dashed drive
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

/// One trip as drawn on the map. Its id changes when the street path arrives or the mode changes,
/// so MapKit replaces the line instead of keeping the first straight one.
private struct RouteLine: Identifiable {
    let id: String
    let mode: TravelMode
    let state: LegState
    let coordinates: [CLLocationCoordinate2D]
    let lineWidth: CGFloat

    @MainActor init(leg: TravelLeg, plan: DayPlan, path: [CLLocationCoordinate2D]) {
        mode = leg.mode
        state = plan.state(of: leg)
        // Transit has no street geometry: a gentle arc reads as "ride", not a route through the park.
        coordinates = leg.mode.isTransit && path.count == 2 ? Self.arc(from: path[0], to: path[1]) : path
        // Dots get big at full width; keep transit lighter.
        lineWidth = leg.mode.isTransit ? max(2, state.lineWidth * 0.6) : state.lineWidth
        id = "\(leg.id)-\(leg.mode.rawValue)-\(coordinates.count)"
    }

    /// A shallow curve bowed to one side, about 12% of the trip's length.
    static func arc(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, steps: Int = 24) -> [CLLocationCoordinate2D] {
        let dLat = b.latitude - a.latitude
        let dLon = b.longitude - a.longitude
        let control = CLLocationCoordinate2D(
            latitude: (a.latitude + b.latitude) / 2 - dLon * 0.12,
            longitude: (a.longitude + b.longitude) / 2 + dLat * 0.12
        )
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            let u = 1 - t
            return CLLocationCoordinate2D(
                latitude: u * u * a.latitude + 2 * u * t * control.latitude + t * t * b.latitude,
                longitude: u * u * a.longitude + 2 * u * t * control.longitude + t * t * b.longitude
            )
        }
    }
}
