import CoreLocation

/// Holds the location manager so the "When In Use" prompt can show the user's dot on the map.
final class LocationPermission {
    private let manager = CLLocationManager()

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
