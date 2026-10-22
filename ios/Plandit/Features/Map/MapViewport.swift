import MapKit
import SwiftUI

@MainActor
enum Manhattan {
    static let center = CLLocationCoordinate2D(latitude: 40.7831, longitude: -73.9712)

    /// Manhattan's street grid runs ~29° east of true north. Rotating the camera keeps the island upright on a phone.
    static let gridHeading: CLLocationDirection = 29

    /// Island extremes (Battery, Inwood, both rivers), used to frame the whole borough.
    static let outline: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 40.7003, longitude: -74.0160), // The Battery
        CLLocationCoordinate2D(latitude: 40.7120, longitude: -73.9760), // Lower East Side waterfront
        CLLocationCoordinate2D(latitude: 40.7560, longitude: -74.0090), // Hudson Yards waterfront
        CLLocationCoordinate2D(latitude: 40.7960, longitude: -73.9290), // East Harlem waterfront
        CLLocationCoordinate2D(latitude: 40.8500, longitude: -73.9480), // Washington Heights waterfront
        CLLocationCoordinate2D(latitude: 40.8780, longitude: -73.9210), // Inwood / Spuyten Duyvil
    ]

    static let overviewCamera = MapCamera(centerCoordinate: center, distance: 36_000, heading: gridHeading, pitch: 0)

    /// Keeps panning and zooming around Manhattan for now.
    static let cameraBounds = MapCameraBounds(
        centerCoordinateBounds: MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.30)),
        minimumDistance: 300,
        maximumDistance: 80_000
    )
}

/// The map's on-screen geometry, used to frame coordinates in the part of the map the sheet doesn't cover.
@MainActor
struct MapViewport: Equatable {
    var size: CGSize = .zero
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// At zero pitch MapKit shows about `distance × ratio` meters of map vertically (≈ a 30° field of view).
    /// Measured on iOS 27 via `onMapCameraChange`; recalibrate if framing looks too tight or loose.
    static let visibleHeightRatio = 0.53

    /// A camera that fits `coordinates` above the sheet, keeping Manhattan's grid upright.
    func camera(
        fitting coordinates: [CLLocationCoordinate2D],
        heading: CLLocationDirection = Manhattan.gridHeading,
        minimumSpan: CLLocationDistance = 900,
        padding: Double = 1.3
    ) -> MapCamera {
        guard let origin = coordinates.first, size.width > 0, size.height > 0 else { return Manhattan.overviewCamera }

        // Project into a local, screen-aligned frame in meters: u points right, v points up.
        let metersPerLat = 110_574.0
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let angle = heading * .pi / 180
        let projected = coordinates.map { coordinate -> (u: Double, v: Double) in
            let x = (coordinate.longitude - origin.longitude) * metersPerLon
            let y = (coordinate.latitude - origin.latitude) * metersPerLat
            return (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
        }
        let us = projected.map(\.u), vs = projected.map(\.v)
        let minU = us.min() ?? 0, maxU = us.max() ?? 0
        let minV = vs.min() ?? 0, maxV = vs.max() ?? 0

        let width = max((maxU - minU) * padding, minimumSpan)
        let height = max((maxV - minV) * padding, minimumSpan)
        let visibleHeight = max(Double(size.height - topInset - bottomInset), 1)
        let metersPerPoint = max(width / Double(size.width), height / visibleHeight)

        // The uncovered area's center sits above the view's center, so move the camera down to compensate.
        let u = (minU + maxU) / 2
        let v = (minV + maxV) / 2 - metersPerPoint * Double(bottomInset - topInset) / 2
        let x = u * cos(angle) + v * sin(angle)
        let y = -u * sin(angle) + v * cos(angle)

        return MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: origin.latitude + y / metersPerLat,
                                                     longitude: origin.longitude + x / metersPerLon),
            distance: metersPerPoint * Double(size.height) / Self.visibleHeightRatio,
            heading: heading,
            pitch: 0
        )
    }
}
