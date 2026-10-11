import MapKit

struct RouteService {
    /// MapKit walking path between two points; falls back to a straight line if directions fail.
    func walkingPath(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = .plandit(at: from)
        request.destination = .plandit(at: to)
        request.transportType = .walking
        guard let route = try? await MKDirections(request: request).calculate().routes.first else {
            return [from, to]
        }
        return route.polyline.coordinates
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
