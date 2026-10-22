import Foundation

/// Mock data for the scaffold. Coordinates are approximate; hours, prices, handles and URLs are placeholders.
/// Replace with the planner + saved-posts backend.
enum SampleData {
    static func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
    }

    // MARK: - Places

    static let hungarianPastry = Place(name: "The Hungarian Pastry Shop", category: .coffee, neighborhood: "Morningside Heights", address: "1030 Amsterdam Ave", latitude: 40.8036, longitude: -73.9636, hours: "Open until 9 PM")
    static let met = Place(name: "The Met", category: .culture, neighborhood: "Upper East Side", address: "1000 Fifth Ave", latitude: 40.7794, longitude: -73.9632, hours: "Open until 5 PM")
    static let highLine = Place(name: "The High Line", category: .outdoors, neighborhood: "Hudson Yards", address: "Enter at W 30th St & 10th Ave", latitude: 40.7527, longitude: -74.0016, hours: "Open until 10 PM")
    static let losTacos = Place(name: "Los Tacos No. 1", category: .food, neighborhood: "Chelsea", address: "75 Ninth Ave, Chelsea Market", latitude: 40.7424, longitude: -74.0061, hours: "Open until 9 PM")
    static let washingtonSquare = Place(name: "Washington Square Park", category: .outdoors, neighborhood: "Greenwich Village", address: "Washington Square", latitude: 40.7308, longitude: -73.9973, hours: "Open until midnight")
    static let joesPizza = Place(name: "Joe's Pizza", category: .food, neighborhood: "West Village", address: "7 Carmine St", latitude: 40.7305, longitude: -74.0021, hours: "Open late")

    static let levain = Place(name: "Levain Bakery", category: .food, neighborhood: "Upper West Side", address: "167 W 74th St", latitude: 40.7799, longitude: -73.9805, hours: "Open until 8 PM")
    static let littleIsland = Place(name: "Little Island", category: .outdoors, neighborhood: "Hudson River Park", address: "Pier 55 at W 13th St", latitude: 40.7420, longitude: -74.0103, hours: "Open until 9 PM")
    static let cloisters = Place(name: "The Met Cloisters", category: .culture, neighborhood: "Fort Tryon Park", address: "99 Margaret Corbin Dr", latitude: 40.8649, longitude: -73.9319, hours: "Open until 5 PM")
    static let smalls = Place(name: "Smalls Jazz Club", category: .nightlife, neighborhood: "West Village", address: "183 W 10th St", latitude: 40.7344, longitude: -74.0027, hours: nil)
    static let russAndDaughters = Place(name: "Russ & Daughters", category: .food, neighborhood: "Lower East Side", address: "179 E Houston St", latitude: 40.7226, longitude: -73.9883, hours: "Open until 6 PM")
    static let tram = Place(name: "Roosevelt Island Tram", category: .activity, neighborhood: "Lenox Hill", address: "E 59th St & 2nd Ave", latitude: 40.7612, longitude: -73.9643, hours: "Runs until 2 AM")

    // MARK: - Saved posts

    static let pastryPost = SavedPost(url: URL(string: "https://www.tiktok.com/@morningside.eats/video/7400000000000000001")!, platform: .tiktok, creatorHandle: "@morningside.eats", caption: "The study spot near campus that lets you stay for hours", savedAt: daysAgo(5), status: .ready, place: hungarianPastry, estimatedCost: 9, tags: ["coffee", "study spot"])
    static let metPost = SavedPost(url: URL(string: "https://www.instagram.com/reel/SAMPLE0002/")!, platform: .instagram, creatorHandle: "@museum.mondays", caption: "NY students: The Met is pay-what-you-wish", savedAt: daysAgo(9), status: .ready, place: met, estimatedCost: 5, tags: ["museum", "student deal"])
    static let highLinePost = SavedPost(url: URL(string: "https://www.instagram.com/reel/SAMPLE0003/")!, platform: .instagram, creatorHandle: "@freenyc.weekends", caption: "Free this weekend: walk the High Line south from Hudson Yards", savedAt: daysAgo(3), status: .ready, place: highLine, estimatedCost: 0, tags: ["free", "walk"])
    static let tacosPost = SavedPost(url: URL(string: "https://www.tiktok.com/@five.dollar.nyc/video/7400000000000000004")!, platform: .tiktok, creatorHandle: "@five.dollar.nyc", caption: "The adobada taco everyone lines up for", savedAt: daysAgo(2), status: .ready, place: losTacos, estimatedCost: 15, tags: ["tacos", "lunch"])
    static let levainPost = SavedPost(url: URL(string: "https://www.tiktok.com/@uws.snacks/video/7400000000000000005")!, platform: .tiktok, creatorHandle: "@uws.snacks", caption: "The cookie that's worth the line", savedAt: daysAgo(1), status: .ready, place: levain, estimatedCost: 6, tags: ["dessert"])
    static let littleIslandPost = SavedPost(url: URL(string: "https://www.instagram.com/reel/SAMPLE0006/")!, platform: .instagram, creatorHandle: "@freenyc.weekends", caption: "Little Island at sunset, completely free", savedAt: daysAgo(4), status: .ready, place: littleIsland, estimatedCost: 0, tags: ["free", "sunset"])
    static let cloistersPost = SavedPost(url: URL(string: "https://www.tiktok.com/@uptown.walks/video/7400000000000000007")!, platform: .tiktok, creatorHandle: "@uptown.walks", caption: "Medieval castle energy at the top of Manhattan", savedAt: daysAgo(12), status: .ready, place: cloisters, estimatedCost: 5, tags: ["museum", "day trip"])
    static let smallsPost = SavedPost(url: URL(string: "https://www.tiktok.com/@jazz.after.class/video/7400000000000000008")!, platform: .tiktok, creatorHandle: "@jazz.after.class", caption: "Late-night jazz in a basement for the price of a drink", savedAt: daysAgo(6), status: .needsReview, place: smalls, estimatedCost: 25, tags: ["jazz", "late night"])
    static let russPost = SavedPost(url: URL(string: "https://www.instagram.com/reel/SAMPLE0009/")!, platform: .instagram, creatorHandle: "@les.bites", caption: "Bagel and lox done right", savedAt: daysAgo(15), status: .ready, place: russAndDaughters, estimatedCost: 18, tags: ["bagels", "brunch"])
    static let tramPost = SavedPost(url: URL(string: "https://www.tiktok.com/@nyc.on.a.budget/video/7400000000000000010")!, platform: .tiktok, creatorHandle: "@nyc.on.a.budget", caption: "Best skyline view for a subway fare", savedAt: daysAgo(20), status: .ready, place: tram, estimatedCost: 2.90, tags: ["views", "budget"])
    static let processingPost = SavedPost(url: URL(string: "https://www.tiktok.com/@sample.creator/video/7400000000000000011")!, platform: .tiktok, savedAt: .now, status: .processing)
    static let failedPost = SavedPost(url: URL(string: "https://www.instagram.com/reel/SAMPLE0012/")!, platform: .instagram, creatorHandle: "@city.moods", caption: "POV: Sunday reset", savedAt: daysAgo(7), status: .failed)

    static let savedPosts: [SavedPost] = [
        processingPost, levainPost, tacosPost, highLinePost, littleIslandPost, pastryPost,
        smallsPost, failedPost, metPost, cloistersPost, russPost, tramPost,
    ]

    // MARK: - Today

    static let dayPlan: DayPlan = {
        let pastry = PlanStop(place: hungarianPastry, start: at(9, 30), durationMinutes: 45, estimatedCost: 9, note: "Quiet start near campus. You saved it from @morningside.eats.", sourcePostID: pastryPost.id, status: .done)
        let museum = PlanStop(place: met, start: at(10, 45), durationMinutes: 120, estimatedCost: 5, note: "Pay what you wish with a NY student ID.", sourcePostID: metPost.id, status: .now)
        let walk = PlanStop(place: highLine, start: at(13, 15), durationMinutes: 75, estimatedCost: 0, note: "Free, and it walks you straight to lunch.", sourcePostID: highLinePost.id, status: .upcoming)
        let lunch = PlanStop(place: losTacos, start: at(14, 45), durationMinutes: 45, estimatedCost: 15, note: "Late lunch after the rush.", sourcePostID: tacosPost.id, status: .upcoming)
        let park = PlanStop(place: washingtonSquare, start: at(16, 0), durationMinutes: 90, estimatedCost: 0, note: "Free time in the park before dinner.", status: .upcoming)
        let dinner = PlanStop(place: joesPizza, start: at(17, 45), durationMinutes: 30, estimatedCost: 7, note: "Two slices keeps you under budget.", status: .upcoming)

        return DayPlan(
            date: .now,
            title: "Morningside to the Village",
            budget: 60,
            stops: [pastry, museum, walk, lunch, park, dinner],
            legs: [
                TravelLeg(fromStopID: pastry.id, toStopID: museum.id, mode: .bus, minutes: 28, miles: 2.1, cost: 2.90, detail: "M4 bus"),
                TravelLeg(fromStopID: museum.id, toStopID: walk.id, mode: .subway, minutes: 35, miles: 3.4, cost: 2.90, detail: "4 and 7 trains"),
                TravelLeg(fromStopID: walk.id, toStopID: lunch.id, mode: .walk, minutes: 18, miles: 0.9),
                TravelLeg(fromStopID: lunch.id, toStopID: park.id, mode: .walk, minutes: 22, miles: 1.1),
                TravelLeg(fromStopID: park.id, toStopID: dinner.id, mode: .walk, minutes: 6, miles: 0.3),
            ]
        )
    }()

    // MARK: - Profile

    static let profile = UserProfile(name: "Abraham", school: "Columbia University", homeBase: "Morningside Heights", defaultBudget: 60, travelModes: "Walk + subway")
    static let stats = UserStats(plansCompleted: 12, neighborhoodsVisited: 9, milesWalked: 41.2, averageSpend: 23, plansUnderBudget: 10, streakWeeks: 3)
    static let pastPlans = [
        PastPlan(title: "Sunday in the West Village", date: daysAgo(6), stopCount: 5, cost: 31),
        PastPlan(title: "Harlem food crawl", date: daysAgo(13), stopCount: 4, cost: 38),
        PastPlan(title: "Free museum Friday", date: daysAgo(22), stopCount: 3, cost: 12),
    ]

    /// Places from past plans, shown as dots on the Profile map.
    static let visitedPlaces: [Place] = [
        hungarianPastry,
        Place(name: "Absolute Bagels", category: .food, neighborhood: "Morningside Heights", address: "2788 Broadway", latitude: 40.8024, longitude: -73.9676),
        Place(name: "Apollo Theater", category: .culture, neighborhood: "Harlem", address: "253 W 125th St", latitude: 40.8100, longitude: -73.9501),
        Place(name: "Sylvia's", category: .food, neighborhood: "Harlem", address: "328 Malcolm X Blvd", latitude: 40.8089, longitude: -73.9445),
        Place(name: "Bethesda Terrace", category: .outdoors, neighborhood: "Central Park", address: "Central Park", latitude: 40.7740, longitude: -73.9708),
        Place(name: "The Morgan Library", category: .culture, neighborhood: "Murray Hill", address: "225 Madison Ave", latitude: 40.7492, longitude: -73.9814),
        Place(name: "Strand Book Store", category: .shopping, neighborhood: "Union Square", address: "828 Broadway", latitude: 40.7332, longitude: -73.9907),
        Place(name: "Katz's Delicatessen", category: .food, neighborhood: "Lower East Side", address: "205 E Houston St", latitude: 40.7223, longitude: -73.9874),
        Place(name: "Battery Park", category: .outdoors, neighborhood: "Financial District", address: "Battery Park", latitude: 40.7033, longitude: -74.0170),
        Place(name: "Fort Tryon Park", category: .outdoors, neighborhood: "Hudson Heights", address: "Fort Tryon Park", latitude: 40.8612, longitude: -73.9325),
        Place(name: "Grand Central Terminal", category: .culture, neighborhood: "Midtown East", address: "89 E 42nd St", latitude: 40.7527, longitude: -73.9772),
    ]

    // MARK: - Stub extraction results

    struct ExtractionMatch {
        var place: Place
        var cost: Double
        var tags: [String]
    }

    static let extractionPool: [ExtractionMatch] = [
        ExtractionMatch(place: Place(name: "Absolute Bagels", category: .food, neighborhood: "Morningside Heights", address: "2788 Broadway", latitude: 40.8024, longitude: -73.9676, hours: "Open until 4 PM"), cost: 5, tags: ["bagels", "budget eats"]),
        ExtractionMatch(place: Place(name: "Strand Book Store", category: .shopping, neighborhood: "Union Square", address: "828 Broadway", latitude: 40.7332, longitude: -73.9907, hours: "Open until 8 PM"), cost: 10, tags: ["books"]),
        ExtractionMatch(place: Place(name: "Fort Tryon Park", category: .outdoors, neighborhood: "Hudson Heights", address: "Fort Tryon Park", latitude: 40.8612, longitude: -73.9325, hours: nil), cost: 0, tags: ["free", "views"]),
        ExtractionMatch(place: Place(name: "Apollo Theater", category: .culture, neighborhood: "Harlem", address: "253 W 125th St", latitude: 40.8100, longitude: -73.9501, hours: "Shows at 7:30 PM"), cost: 25, tags: ["show"]),
    ]
}
