import CoreLocation
import MapKit

struct Place: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    var category: PlaceCategory
    var neighborhood: String
    var address: String
    var latitude: Double
    var longitude: Double
    var hours: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Hands off to Apple Maps for turn-by-turn directions by walking, transit or car.
    /// With `from`, the route starts at that place instead of where the user is.
    func openDirections(by mode: TravelMode = .walk, from origin: Place? = nil) {
        let destination = MKMapItem.plandit(at: coordinate, name: name)
        let options = [MKLaunchOptionsDirectionsModeKey: mode.mapsLaunchMode]
        if let origin {
            MKMapItem.openMaps(with: [.plandit(at: origin.coordinate, name: origin.name), destination], launchOptions: options)
        } else {
            destination.openInMaps(launchOptions: options)
        }
    }
}

enum PlaceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, coffee, activity, outdoors, culture, nightlife, shopping

    var id: String { rawValue }

    var label: String {
        switch self {
        case .food: "Food"
        case .coffee: "Coffee"
        case .activity: "Activity"
        case .outdoors: "Outdoors"
        case .culture: "Culture"
        case .nightlife: "Nightlife"
        case .shopping: "Shopping"
        }
    }

    var icon: Lucide {
        switch self {
        case .food: .utensils
        case .coffee: .coffee
        case .activity: .ticket
        case .outdoors: .trees
        case .culture: .landmark
        case .nightlife: .martini
        case .shopping: .shoppingBag
        }
    }
}

extension MKMapItem {
    static func plandit(at coordinate: CLLocationCoordinate2D, name: String? = nil) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }
}
