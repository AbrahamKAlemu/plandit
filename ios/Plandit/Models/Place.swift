import CoreLocation
import MapKit

struct Place: Identifiable, Hashable, Codable {
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

    /// Hands off to Apple Maps for turn-by-turn walking directions.
    func openDirections() {
        MKMapItem.plandit(at: coordinate, name: name)
            .openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

enum PlaceCategory: String, Codable, CaseIterable, Identifiable {
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
