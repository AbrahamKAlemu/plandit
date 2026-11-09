import MapKit

/// What Apple Maps says about one way of getting between two stops.
struct RouteInfo: Equatable {
    var minutes: Int
    var miles: Double
    /// The line to draw. Walking and driving only: MapKit gives transit times but no transit geometry.
    var path: [CLLocationCoordinate2D]?

    static func == (a: RouteInfo, b: RouteInfo) -> Bool {
        a.minutes == b.minutes && a.miles == b.miles && a.path?.count == b.path?.count
    }
}

/// Apple Maps routes, behind a protocol so tests don't hit the network.
protocol RouteProviding: Sendable {
    func route(_ mode: TravelMode, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> RouteInfo?
}

struct RouteService: RouteProviding {
    /// nil when Apple Maps has no answer (offline, no transit service, too close). Callers fall back to estimates.
    func route(_ mode: TravelMode, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> RouteInfo? {
        let request = MKDirections.Request()
        request.source = .plandit(at: from)
        request.destination = .plandit(at: to)
        request.transportType = mode.transportType
        let directions = MKDirections(request: request)
        if mode.isTransit {
            guard let eta = try? await directions.calculateETA() else { return nil }
            return RouteInfo(minutes: Self.minutes(eta.expectedTravelTime), miles: eta.distance / 1609.34, path: nil)
        }
        guard let route = try? await directions.calculate().routes.first else { return nil }
        return RouteInfo(minutes: Self.minutes(route.expectedTravelTime), miles: route.distance / 1609.34, path: route.polyline.coordinates)
    }

    /// Walking path between two points; a straight line if directions fail.
    func walkingPath(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [CLLocationCoordinate2D] {
        await route(.walk, from: from, to: to)?.path ?? [from, to]
    }

    private static func minutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }
}

extension TravelMode {
    var transportType: MKDirectionsTransportType {
        switch self {
        case .walk: .walking
        case .subway, .bus: .transit
        case .drive: .automobile
        }
    }

    /// Apple Maps opens turn-by-turn in this mode, including real subway lines and transfers.
    var mapsLaunchMode: String {
        switch self {
        case .walk: MKLaunchOptionsDirectionsModeWalking
        case .subway, .bus: MKLaunchOptionsDirectionsModeTransit
        case .drive: MKLaunchOptionsDirectionsModeDriving
        }
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
