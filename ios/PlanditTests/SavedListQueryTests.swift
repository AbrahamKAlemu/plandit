import XCTest
@testable import Plandit

/// The Saved list's category pictures, Filter and Sort menus, and slim rows (D-3, D-4, D-5, PRC-5).
final class SavedListQueryTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private func post(
        _ name: String,
        _ category: PlaceCategory,
        hoursAgo: Double,
        cost: Double? = nil,
        userCost: Double? = nil,
        status: ExtractionStatus = .ready
    ) -> SavedPost {
        SavedPost(
            url: URL(string: "https://www.tiktok.com/@test/video/\(abs(name.hashValue))")!,
            platform: .tiktok,
            savedAt: base.addingTimeInterval(-hoursAgo * 3600),
            status: status,
            place: Place(name: name, category: category, neighborhood: "Chelsea", address: "1 Main St", latitude: 40.74, longitude: -74),
            estimatedCost: cost,
            userCost: userCost
        )
    }

    @MainActor private func unplaced(_ status: ExtractionStatus, hoursAgo: Double = 0) -> SavedPost {
        SavedPost(
            url: URL(string: "https://www.tiktok.com/@test/video/\(UUID().uuidString)")!,
            platform: .tiktok,
            savedAt: base.addingTimeInterval(-hoursAgo * 3600),
            status: status
        )
    }

    // MARK: - Category groups (D-3)

    @MainActor func testShoppingAndEveryOtherCategoryHaveAGroup() {
        XCTAssertEqual(SavedCategoryGroup(.food), .food)
        XCTAssertEqual(SavedCategoryGroup(.coffee), .coffee)
        XCTAssertEqual(SavedCategoryGroup(.activity), .activity)
        XCTAssertEqual(SavedCategoryGroup(.outdoors), .outdoors)
        XCTAssertEqual(SavedCategoryGroup(.nightlife), .nightlife)
        XCTAssertEqual(SavedCategoryGroup(.culture), .culture)
        XCTAssertEqual(SavedCategoryGroup(.shopping), .others)
        XCTAssertEqual(SavedCategoryGroup.allCases.map(\.label), ["Food", "Coffee", "Activity", "Outdoors", "Nightlife", "Culture", "Others"])
        XCTAssertEqual(SavedCategoryGroup.others.imageName, "Categories/others")
    }

    @MainActor func testOnlyGroupsWithASavedPlaceAppearInOrderWithCounts() {
        let posts = [
            post("Bar", .nightlife, hoursAgo: 1),
            post("Shop", .shopping, hoursAgo: 2),
            post("Tacos", .food, hoursAgo: 3),
            post("Pizza", .food, hoursAgo: 4),
            unplaced(.processing),
            unplaced(.needsConfirmation),
        ]
        let groups = SavedListQuery.groups(in: posts)
        XCTAssertEqual(groups.map(\.group), [.food, .nightlife, .others])
        XCTAssertEqual(groups.map(\.count), [2, 1, 1])
        XCTAssertEqual(groups.first?.accessibilityLabel, "Food, 2 places")
        XCTAssertEqual(groups.last?.accessibilityLabel, "Others, 1 place")
        XCTAssertTrue(SavedListQuery.groups(in: [unplaced(.processing)]).isEmpty)
    }

    @MainActor func testSelectingAGroupShowsOnlyItsPlaces() {
        let tacos = post("Tacos", .food, hoursAgo: 1)
        let shop = post("Shop", .shopping, hoursAgo: 2)
        let park = post("Park", .outdoors, hoursAgo: 3)
        let finding = unplaced(.processing)
        let posts = [finding, tacos, shop, park]

        XCTAssertEqual(SavedListQuery().apply(to: posts).map(\.id), posts.map(\.id), "All also shows posts without a place")
        XCTAssertEqual(SavedListQuery(group: .food).apply(to: posts).map(\.id), [tacos.id])
        XCTAssertEqual(SavedListQuery(group: .others).apply(to: posts).map(\.id), [shop.id], "shopping shows under Others")
        XCTAssertTrue(SavedListQuery(group: .coffee).apply(to: posts).isEmpty)
    }

    @MainActor func testTappingTheSelectedGroupAgainShowsAll() {
        var query = SavedListQuery()
        query.toggle(.food)
        XCTAssertEqual(query.group, .food)
        query.toggle(.coffee)
        XCTAssertEqual(query.group, .coffee)
        query.toggle(.coffee)
        XCTAssertNil(query.group)
    }

    @MainActor func testAGroupThatEmptiedOutNoLongerFilters() {
        let tacos = post("Tacos", .food, hoursAgo: 1)
        let query = SavedListQuery(group: .coffee).resolved(for: [tacos])
        XCTAssertNil(query.group, "the last coffee place was removed, so its picture is gone and the list shows all")
        XCTAssertEqual(SavedListQuery(group: .food).resolved(for: [tacos]).group, .food)
    }

    // MARK: - Filter and Sort (D-4)

    @MainActor func testFreeOnlyHidesPlacesThatCostMoney() {
        let park = post("Park", .outdoors, hoursAgo: 1) // typical park price is $0
        let paidPark = post("Zoo", .outdoors, hoursAgo: 2, cost: 12)
        let freeMuseum = post("Museum", .culture, hoursAgo: 3, cost: 0)
        let tacos = post("Tacos", .food, hoursAgo: 4, cost: 15)
        let userFree = post("Pizza", .food, hoursAgo: 5, cost: 4, userCost: 0)
        let finding = unplaced(.processing)
        let posts = [park, paidPark, freeMuseum, tacos, userFree, finding]

        let free = SavedListQuery(filter: .freeOnly).apply(to: posts)
        XCTAssertEqual(free.map(\.id), [park.id, freeMuseum.id, userFree.id], "free only also hides posts without a place")
        XCTAssertTrue(SavedListQuery.isFree(park))
        XCTAssertFalse(SavedListQuery.isFree(paidPark))
        XCTAssertFalse(SavedListQuery.isFree(finding))

        let freeFood = SavedListQuery(group: .food, filter: .freeOnly).apply(to: posts)
        XCTAssertEqual(freeFood.map(\.id), [userFree.id], "free only combines with a category")
    }

    @MainActor func testOldestReversesTheOrder() {
        let newest = post("A", .food, hoursAgo: 1)
        let middle = post("B", .coffee, hoursAgo: 5)
        let oldest = post("C", .food, hoursAgo: 30)
        let posts = [middle, oldest, newest]

        XCTAssertEqual(SavedListQuery().apply(to: posts).map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertEqual(SavedListQuery(sort: .oldest).apply(to: posts).map(\.id), [oldest.id, middle.id, newest.id])
        XCTAssertEqual(SavedListQuery(group: .food, sort: .oldest).apply(to: posts).map(\.id), [oldest.id, newest.id], "sort combines with a category")
    }

    @MainActor func testMenuLabelsShowOnlyANonDefaultChoice() {
        XCTAssertEqual(SavedListQuery().filterTitle, "Filter")
        XCTAssertEqual(SavedListQuery(filter: .freeOnly).filterTitle, "Free only")
        XCTAssertEqual(SavedListQuery().sortTitle, "Sort")
        XCTAssertEqual(SavedListQuery(sort: .oldest).sortTitle, "Oldest")
        XCTAssertEqual(SavedFilter.allCases.map(\.label), ["All", "Free only"])
        XCTAssertEqual(SavedSort.allCases.map(\.label), ["Newest", "Oldest"])
    }

    // MARK: - Rows (D-5, PRC-5)

    @MainActor func testRowDetailIsCategoryAndNeighborhoodPlusFree() {
        XCTAssertEqual(post("Tacos", .food, hoursAgo: 1, cost: 15).savedRowDetail, "Food · Chelsea")
        let park = post("Park", .outdoors, hoursAgo: 1)
        XCTAssertEqual(park.savedRowDetail, "Outdoors · Chelsea · Free")
        XCTAssertTrue(park.isFreeInSaved)
        XCTAssertNil(unplaced(.processing).savedRowDetail)
        XCTAssertEqual(SampleData.levainPost.savedRowDetail, "Food · Upper West Side", "no price on the row")
    }

    @MainActor func testRowTrailingStatusWords() {
        XCTAssertEqual(SavedRowTrailing(post: unplaced(.processing), isInToday: false), .status("Finding…"))
        XCTAssertEqual(SavedRowTrailing(post: unplaced(.needsEvidence), isInToday: false), .status("Add the place"))
        XCTAssertEqual(SavedRowTrailing(post: unplaced(.needsConfirmation), isInToday: false), .status("Pick the place"))
        XCTAssertEqual(SavedRowTrailing(post: unplaced(.failed), isInToday: false), .status("Couldn't find it"))
        XCTAssertEqual(SavedRowTrailing(post: post("Smalls", .nightlife, hoursAgo: 1, status: .needsReview), isInToday: false), .status("Check this place"))
        XCTAssertEqual(SavedRowTrailing(post: post("Smalls", .nightlife, hoursAgo: 1, status: .needsReview), isInToday: true), .inPlan)
        XCTAssertEqual(SavedRowTrailing(post: post("Tacos", .food, hoursAgo: 1), isInToday: false), .add)
        XCTAssertEqual(SavedRowTrailing(post: post("Tacos", .food, hoursAgo: 1), isInToday: true), .inPlan)
        XCTAssertEqual(SavedRowTrailing.inPlan.text, "In plan")
        XCTAssertNil(SavedRowTrailing.add.text)
    }

    // MARK: - + on a row

    @MainActor func testPlusOnAnEmptyDayStartsTodaysPlanWithThatPlace() {
        let levain = SampleData.levainPost
        let store = PlanditStore(
            today: DayPlan(date: .now, title: "Today", budget: 60, stops: [], legs: []),
            saved: [levain], profile: SampleData.profile,
            pastPlans: [], visited: [], extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), storage: nil
        )
        XCTAssertFalse(store.isInToday(levain))
        XCTAssertEqual(SavedRowTrailing(post: levain, isInToday: store.isInToday(levain)), .add)

        XCTAssertNotNil(store.addToToday(levain.id))

        XCTAssertEqual(store.today.stops.map(\.place.name), ["Levain Bakery"])
        XCTAssertTrue(store.isInToday(levain))
        XCTAssertEqual(SavedRowTrailing(post: levain, isInToday: store.isInToday(levain)), .inPlan)
    }
}
