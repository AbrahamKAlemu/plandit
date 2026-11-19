import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import Plandit

/// W-4: on iPad the full-height sheet is a centered panel, so the map frames content in the strip
/// beside it instead of above it (where 1.0 showed Newark).
final class MapViewportTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    private let iPadMini = CGSize(width: 744, height: 1133)

    @MainActor private func viewport(_ size: CGSize, top: CGFloat = 24) -> MapViewport {
        var viewport = MapViewport()
        viewport.size = size
        viewport.topInset = top
        return viewport
    }

    @MainActor func testWithoutAPanelContentIsFramedAboveTheSheet() {
        let framing = viewport(phone, top: 62).uncovered(coveredHeight: 470, fullHeightPanel: nil)

        XCTAssertEqual(framing.bottomInset, 470)
        XCTAssertEqual(framing.leadingInset, 0)
        XCTAssertEqual(framing.trailingInset, 0)
    }

    @MainActor func testFullWidthSheetKeepsFramingAboveIt() {
        let framing = viewport(phone, top: 62).uncovered(coveredHeight: 470, fullHeightPanel: 0...402)

        XCTAssertEqual(framing.bottomInset, 470)
        XCTAssertEqual(framing.trailingInset, 0)
    }

    @MainActor func testFullHeightPanelFramesTheStripBesideIt() {
        let framing = viewport(iPadMini).uncovered(coveredHeight: 605, fullHeightPanel: 88...656)

        XCTAssertEqual(framing.bottomInset, 0, "the strip runs the full height")
        XCTAssertEqual(framing.leadingInset, 0)
        XCTAssertEqual(framing.trailingInset, 744 - 88, "everything from the panel's leading edge on is covered")
    }

    @MainActor func testPanelOffToOneSideFramesTheWiderStrip() {
        let framing = viewport(iPadMini).uncovered(coveredHeight: 605, fullHeightPanel: 20...420)

        XCTAssertEqual(framing.leadingInset, 420)
        XCTAssertEqual(framing.trailingInset, 0)
    }

    @MainActor func testCameraCentersManhattanInTheStripBesideThePanel() {
        let framing = viewport(iPadMini).uncovered(coveredHeight: 605, fullHeightPanel: 88...656)
        let camera = framing.camera(fitting: Manhattan.outline)

        // Where Manhattan's middle lands on screen, measured from the view's center.
        let scale = camera.distance * MapViewport.visibleHeightRatio / Double(iPadMini.height)
        let offset = screenOffset(of: middle(of: Manhattan.outline), from: camera, metersPerPoint: scale)
        let stripCenter = 88.0 / 2
        XCTAssertEqual(Double(iPadMini.width) / 2 + offset.x, stripCenter, accuracy: 2, "Manhattan sits in the strip, not behind the panel")
    }

    @MainActor func testCameraNeverAsksForMoreThanTheMapsFarthestZoom() {
        let framing = viewport(iPadMini).uncovered(coveredHeight: 605, fullHeightPanel: 88...656)
        let camera = framing.camera(fitting: Manhattan.outline)

        XCTAssertLessThanOrEqual(camera.distance, Manhattan.maximumDistance + 1,
                                 "MapKit clamps farther cameras, which would throw the centering off")
    }

    @MainActor func testPhoneFramingIsUnchangedWhenTheZoomFits() {
        var phoneViewport = viewport(phone, top: 62)
        phoneViewport.bottomInset = 470
        let stops = [
            CLLocationCoordinate2D(latitude: 40.8075, longitude: -73.9626),
            CLLocationCoordinate2D(latitude: 40.7480, longitude: -74.0048),
        ]
        let camera = phoneViewport.camera(fitting: stops)

        let scale = camera.distance * MapViewport.visibleHeightRatio / Double(phone.height)
        let offset = screenOffset(of: middle(of: stops), from: camera, metersPerPoint: scale)
        let openMiddle = (62.0 + (874.0 - 470.0)) / 2
        XCTAssertEqual(Double(phone.height) / 2 - offset.y, openMiddle, accuracy: 1, "stops sit in the middle of the open map")
        XCTAssertEqual(offset.x, 0, accuracy: 1)
    }

    @MainActor func testClampedZoomStillCentersContentInTheOpenMapAtHalfHeight() {
        // iPhone 17 Pro at half height: all of Manhattan needs more than the farthest zoom.
        var phoneViewport = viewport(phone, top: 62)
        phoneViewport.bottomInset = SheetDetent.coveredHeight(.medium, screenHeight: phone.height)
        let camera = phoneViewport.camera(fitting: Manhattan.outline)

        XCTAssertEqual(camera.distance, Manhattan.maximumDistance, accuracy: 1, "the clamp applies here")
        let scale = camera.distance * MapViewport.visibleHeightRatio / Double(phone.height)
        let offset = screenOffset(of: middle(of: Manhattan.outline), from: camera, metersPerPoint: scale)
        let openMiddle = (62.0 + Double(phone.height - phoneViewport.bottomInset)) / 2
        XCTAssertEqual(Double(phone.height) / 2 - offset.y, openMiddle, accuracy: 1, "Manhattan's middle sits in the middle of the open map")
        XCTAssertEqual(offset.x, 0, accuracy: 1)
    }

    @MainActor func testCameraCenterStaysWhereMapKitAllowsIt() {
        // Coney Island and the Battery, framed above a half-height sheet: the center we'd compute
        // falls south of the allowed region, and MapKit would move it somewhere we didn't frame.
        let coneyIsland = CLLocationCoordinate2D(latitude: 40.5755, longitude: -73.9707)
        let battery = CLLocationCoordinate2D(latitude: 40.7033, longitude: -74.0170)
        var phoneViewport = viewport(phone, top: 62)
        phoneViewport.bottomInset = SheetDetent.coveredHeight(.medium, screenHeight: phone.height)
        let center = phoneViewport.camera(fitting: [coneyIsland, battery]).centerCoordinate

        let allowed = Manhattan.centerBounds
        XCTAssertGreaterThanOrEqual(center.latitude, allowed.center.latitude - allowed.span.latitudeDelta / 2 - 1e-9)
        XCTAssertLessThanOrEqual(center.latitude, allowed.center.latitude + allowed.span.latitudeDelta / 2 + 1e-9)
        XCTAssertGreaterThanOrEqual(center.longitude, allowed.center.longitude - allowed.span.longitudeDelta / 2 - 1e-9)
        XCTAssertLessThanOrEqual(center.longitude, allowed.center.longitude + allowed.span.longitudeDelta / 2 + 1e-9)
    }

    @MainActor func testProfileFramesVisitedPlacesOrManhattanBeforeThereAreAny() {
        let visited = [SampleData.hungarianPastry, SampleData.losTacos].map(\.coordinate)
        XCTAssertEqual(Manhattan.profileFocus(visited: visited).map(\.latitude), visited.map(\.latitude))
        XCTAssertEqual(Manhattan.profileFocus(visited: []).map(\.latitude), Manhattan.outline.map(\.latitude))
    }

    @MainActor func testVisitedPinsThatFitTheFarthestZoomAreAllAboveTheSheetAtHalfHeight() {
        // Morningside Heights to Murray Hill fits. All of the sample (Battery Park to Fort Tryon,
        // ~18.7 km along the grid) doesn't: at 80 km the open map above a half-height sheet on
        // this phone holds ~16.6 km, so the ends spill past it whatever the framing.
        let visited = SampleData.visitedPlaces
            .filter { ["Morningside Heights", "Harlem", "Central Park", "Midtown East", "Murray Hill"].contains($0.neighborhood) }
            .map(\.coordinate)
        XCTAssertGreaterThanOrEqual(visited.count, 5)
        var phoneViewport = viewport(phone, top: 62)
        phoneViewport.bottomInset = SheetDetent.coveredHeight(.medium, screenHeight: phone.height)
        let camera = phoneViewport.camera(fitting: Manhattan.profileFocus(visited: visited))

        let scale = camera.distance * MapViewport.visibleHeightRatio / Double(phone.height)
        for pin in visited {
            let offset = screenOffset(of: pin, from: camera, metersPerPoint: scale)
            let y = Double(phone.height) / 2 - offset.y
            let x = Double(phone.width) / 2 + offset.x
            XCTAssertGreaterThanOrEqual(y, 62, "below the status bar")
            XCTAssertLessThanOrEqual(y, Double(phone.height - phoneViewport.bottomInset), "above the sheet")
            XCTAssertGreaterThanOrEqual(x, 0)
            XCTAssertLessThanOrEqual(x, Double(phone.width))
        }
    }

    // MARK: - Helpers

    @MainActor private func middle(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        // The same rotated bounding-box middle `camera(fitting:)` aims for.
        let origin = coordinates[0]
        let metersPerLat = 110_574.0
        let metersPerLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let angle = Manhattan.gridHeading * .pi / 180
        let projected = coordinates.map { coordinate -> (u: Double, v: Double) in
            let x = (coordinate.longitude - origin.longitude) * metersPerLon
            let y = (coordinate.latitude - origin.latitude) * metersPerLat
            return (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
        }
        let u = ((projected.map(\.u).min() ?? 0) + (projected.map(\.u).max() ?? 0)) / 2
        let v = ((projected.map(\.v).min() ?? 0) + (projected.map(\.v).max() ?? 0)) / 2
        let x = u * cos(angle) + v * sin(angle)
        let y = -u * sin(angle) + v * cos(angle)
        return CLLocationCoordinate2D(latitude: origin.latitude + y / metersPerLat, longitude: origin.longitude + x / metersPerLon)
    }

    /// Screen offset in points (x right, y up) of `coordinate` from the camera's center.
    @MainActor private func screenOffset(of coordinate: CLLocationCoordinate2D, from camera: MapCamera, metersPerPoint: Double) -> (x: Double, y: Double) {
        let center = camera.centerCoordinate
        let metersPerLat = 110_574.0
        let metersPerLon = 111_320.0 * cos(center.latitude * .pi / 180)
        let x = (coordinate.longitude - center.longitude) * metersPerLon
        let y = (coordinate.latitude - center.latitude) * metersPerLat
        let angle = camera.heading * .pi / 180
        return ((x * cos(angle) - y * sin(angle)) / metersPerPoint, (x * sin(angle) + y * cos(angle)) / metersPerPoint)
    }
}
