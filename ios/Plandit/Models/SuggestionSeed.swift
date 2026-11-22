#if DEBUG
import Foundation

/// `-seedSuggestions` (debug builds only): an empty Today and five saved places in two clusters, with
/// fixed hours and prices, so `SuggestedPlansFlowTests` always sees the same suggested plans. Launch
/// with `-planStart 14:00` too: the plans depend on the start time.
///
/// Chelsea: Chelsea Market, The High Line and Little Island, a few minutes' walk apart.
/// Upper West Side: Levain Bakery and the natural history museum, over 3 miles from Chelsea.
enum SuggestionSeed {
    static var savedPosts: [SavedPost] {
        [
            post(1, "Chelsea Market", .food, "Chelsea", "75 Ninth Ave", 40.7424, -74.0061, hours: "Open until 9 PM", cost: 15),
            post(2, "The High Line", .outdoors, "Chelsea", "Enter at Gansevoort St", 40.7398, -74.0080, hours: "Open until 10 PM", cost: 0),
            post(3, "Little Island", .outdoors, "Hudson River Park", "Pier 55 at W 13th St", 40.7420, -74.0103, hours: "Open until 9 PM", cost: 0),
            post(4, "Levain Bakery", .food, "Upper West Side", "167 W 74th St", 40.7799, -73.9805, hours: "Open until 8 PM", cost: 6),
            post(5, "Natural History Museum", .culture, "Upper West Side", "200 Central Park West", 40.7813, -73.9740, hours: "Open until 5:30 PM", cost: 28),
        ]
    }

    private static func post(
        _ number: Int, _ name: String, _ category: PlaceCategory, _ neighborhood: String, _ address: String,
        _ latitude: Double, _ longitude: Double, hours: String, cost: Double
    ) -> SavedPost {
        SavedPost(
            id: UUID(uuidString: "5EED0000-0000-4000-8000-00000000000\(number)")!,
            url: URL(string: "https://www.tiktok.com/@seed.saves/video/740000000000000090\(number)")!,
            platform: .tiktok,
            creatorHandle: "@seed.saves",
            caption: "Saved for a free afternoon",
            savedAt: SampleData.daysAgo(number),
            status: .ready,
            place: Place(name: name, category: category, neighborhood: neighborhood, address: address,
                         latitude: latitude, longitude: longitude, hours: hours),
            estimatedCost: cost
        )
    }
}
#endif
