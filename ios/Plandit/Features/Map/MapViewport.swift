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

    /// The farthest the map zooms out. MapKit clamps any camera beyond it.
    static let maximumDistance: CLLocationDistance = 80_000

    /// Where the camera's center may go: about lat 40.62 to 40.94, lon −74.12 to −73.82.
    static let centerBounds = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.30))

    /// Keeps panning and zooming around Manhattan for now.
    static let cameraBounds = MapCameraBounds(
        centerCoordinateBounds: centerBounds,
        minimumDistance: 300,
        maximumDistance: maximumDistance
    )
}

extension Manhattan {
    /// What Profile's map frames: the places you've been, which are its pins, or the whole island
    /// before there are any.
    static func profileFocus(visited: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        visited.isEmpty ? outline : visited
    }
}

/// The map's on-screen geometry, used to frame coordinates in the part of the map the sheet doesn't cover.
@MainActor
struct MapViewport: Equatable {
    var size: CGSize = .zero
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    /// At zero pitch MapKit shows about `distance × ratio` meters of map vertically (≈ a 30° field of view).
    /// Measured on iOS 27 via `onMapCameraChange`; recalibrate if framing looks too tight or loose.
    static let visibleHeightRatio = 0.53

    /// A strip narrower than this isn't worth framing into; the map frames above the sheet instead.
    static let minimumStripWidth: CGFloat = 44

    /// The open part of the map. Usually that's above the sheet, which covers `coveredHeight`. On
    /// iPad at full height the sheet is a centered panel (`panel` is its horizontal extent on
    /// screen) that hides the middle of the map, so the open part is the wider strip beside it.
    func uncovered(coveredHeight: CGFloat, fullHeightPanel panel: ClosedRange<CGFloat>?) -> MapViewport {
        var viewport = self
        viewport.bottomInset = coveredHeight
        guard let panel else { return viewport }

        let leadingStrip = panel.lowerBound
        let trailingStrip = size.width - panel.upperBound
        guard max(leadingStrip, trailingStrip) >= Self.minimumStripWidth else { return viewport }

        viewport.bottomInset = 0
        if leadingStrip >= trailingStrip {
            viewport.trailingInset = size.width - panel.lowerBound
        } else {
            viewport.leadingInset = panel.upperBound
        }
        return viewport
    }

    /// A camera that fits `coordinates` in the part of the map the sheet leaves open, keeping Manhattan's grid upright.
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
        let visibleWidth = max(Double(size.width - leadingInset - trailingInset), 1)
        let visibleHeight = max(Double(size.height - topInset - bottomInset), 1)
        // Never farther out than MapKit allows: it would clamp the zoom and the offsets below would miss.
        let farthest = Manhattan.maximumDistance * Self.visibleHeightRatio / Double(size.height)
        let metersPerPoint = min(max(width / visibleWidth, height / visibleHeight), farthest)

        // The uncovered area's center is off the view's center (above it, or beside it next to an
        // iPad panel), so move the camera the other way to compensate.
        let u = (minU + maxU) / 2 - metersPerPoint * Double(leadingInset - trailingInset) / 2
        let v = (minV + maxV) / 2 - metersPerPoint * Double(bottomInset - topInset) / 2
        let x = u * cos(angle) + v * sin(angle)
        let y = -u * sin(angle) + v * cos(angle)

        // Keep the center where `cameraBounds` allows it; otherwise MapKit moves it on its own.
        let allowed = Manhattan.centerBounds
        let latitude = min(max(origin.latitude + y / metersPerLat, allowed.center.latitude - allowed.span.latitudeDelta / 2),
                           allowed.center.latitude + allowed.span.latitudeDelta / 2)
        let longitude = min(max(origin.longitude + x / metersPerLon, allowed.center.longitude - allowed.span.longitudeDelta / 2),
                            allowed.center.longitude + allowed.span.longitudeDelta / 2)

        return MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            distance: metersPerPoint * Double(size.height) / Self.visibleHeightRatio,
            heading: heading,
            pitch: 0
        )
    }
}
