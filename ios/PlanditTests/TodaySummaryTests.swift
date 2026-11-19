import XCTest
@testable import Plandit

/// Today's summary tile for getting around: miles walked, or the rides when nobody walks.
/// The tile is a value over a caption, so "2 subway rides" shows as "2" over "subway rides".
@MainActor final class TodaySummaryTests: XCTestCase {
    /// A day of `modes.count + 1` stops joined by trips made these ways. Walks are `walkMiles` long.
    private func day(_ modes: [TravelMode], walkMiles: Double = 1.2) -> DayPlan {
        let places = [SampleData.met, SampleData.highLine, SampleData.losTacos, SampleData.washingtonSquare, SampleData.joesPizza]
        let stops = places.prefix(modes.count + 1).enumerated().map { index, place in
            PlanStop(place: place, start: SampleData.at(10 + index * 2), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        }
        let legs = zip(zip(stops, stops.dropFirst()), modes).map { pair, mode in
            TravelLeg.estimate(mode, miles: mode == .walk ? walkMiles : 1.2, fromStopID: pair.0.id, toStopID: pair.1.id)
        }
        return DayPlan(date: .now, title: "Today", budget: 60, stops: Array(stops), legs: legs)
    }

    private func travel(_ modes: [TravelMode], walkMiles: Double = 1.2) throws -> TodaySummaryText.Travel {
        try XCTUnwrap(TodaySummaryText.travel(day(modes, walkMiles: walkMiles)), "\(modes) has a travel tile")
    }

    /// What the tile reads as one line.
    private func tile(_ modes: [TravelMode]) throws -> String {
        let travel = try travel(modes)
        return "\(travel.value) \(travel.caption)"
    }

    func testSubwayOnlyDayCountsSubwayRides() throws {
        let travel = try travel([.subway, .subway])
        XCTAssertEqual(travel.value, "2")
        XCTAssertEqual(travel.caption, "subway rides")
        XCTAssertEqual(travel.icon, .trainFront)
        XCTAssertEqual(try tile([.subway, .subway]), "2 subway rides")
        XCTAssertEqual(try tile([.subway]), "1 subway ride")
    }

    func testBusOnlyDayCountsBusRides() throws {
        XCTAssertEqual(try tile([.bus]), "1 bus ride")
        XCTAssertEqual(try travel([.bus]).icon, .bus)
        XCTAssertEqual(try tile([.bus, .bus, .bus]), "3 bus rides")
    }

    func testMixedTransitNamesEachKind() throws {
        let travel = try travel([.subway, .bus])
        XCTAssertEqual(travel.value, "2 rides")
        XCTAssertEqual(travel.caption, "1 subway, 1 bus")
        XCTAssertEqual(travel.icon, .trainFront, "ties go to the subway")
        XCTAssertEqual(try self.travel([.bus, .subway, .subway]).caption, "2 subway, 1 bus")
        XCTAssertEqual(try self.travel([.bus, .bus, .subway]).icon, .bus, "the icon follows the most common kind")
    }

    func testDriveOnlyDayCountsDrives() throws {
        XCTAssertEqual(try tile([.drive]), "1 drive")
        XCTAssertEqual(try travel([.drive]).icon, .car)
        XCTAssertEqual(try tile([.drive, .drive]), "2 drives")
        XCTAssertEqual(try travel([.subway, .drive]).caption, "1 subway, 1 drive")
        XCTAssertEqual(try travel([.subway, .drive, .drive]).caption, "1 subway, 2 drives")
    }

    func testWalkingPlusTransitKeepsMilesWalked() throws {
        let plan = day([.walk, .subway])
        let travel = try XCTUnwrap(TodaySummaryText.travel(plan))
        XCTAssertEqual(travel.value, plan.walkingMiles.milesText)
        XCTAssertEqual(travel.value, "1.2 mi")
        XCTAssertEqual(travel.caption, "Walking")
        XCTAssertEqual(travel.icon, .footprints)
    }

    func testNeverSaysZeroMilesWalkingOnADayWithRides() throws {
        for modes in [[TravelMode.subway], [.bus], [.drive], [.subway, .bus, .drive]] {
            let travel = try travel(modes)
            XCTAssertNotEqual(travel.value, "0.0 mi", "\(modes)")
            XCTAssertNotEqual(travel.caption, "Walking", "\(modes)")
        }
    }

    // MARK: - Edge cases

    func testADayWithNoTripsHasNoTravelTile() {
        XCTAssertNil(TodaySummaryText.travel(day([])), "one stop: nothing to say about getting around, not \"0.0 mi Walking\"")
        XCTAssertNil(TodaySummaryText.completedTravel(day([])))
    }

    func testWalkingThatRoundsToNothingShowsTheRidesInstead() throws {
        let travel = try travel([.walk, .subway, .subway], walkMiles: 0.02)
        XCTAssertEqual(travel.value, "2")
        XCTAssertEqual(travel.caption, "subway rides")
        XCTAssertEqual(travel.icon, .trainFront)
        XCTAssertEqual(travel.accessibilityLabel, "2 subway rides")

        let mixed = try self.travel([.walk, .subway, .drive], walkMiles: 0.02)
        XCTAssertEqual(mixed.value, "2 rides")
        XCTAssertEqual(mixed.caption, "1 subway, 1 drive")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.walk, .subway, .subway], walkMiles: 0.02)), "2 subway rides")
    }

    func testShortWalksOnlyCountTheWalks() throws {
        let travel = try travel([.walk, .walk], walkMiles: 0.02)
        XCTAssertEqual(travel.value, "2")
        XCTAssertEqual(travel.caption, "walks")
        XCTAssertEqual(travel.icon, .footprints)
        XCTAssertEqual(travel.accessibilityLabel, "2 walks")
    }

    // MARK: - VoiceOver

    func testVoiceOverReadsTheTileAsOnePhrase() throws {
        XCTAssertEqual(try travel([.subway, .subway]).accessibilityLabel, "2 subway rides")
        XCTAssertEqual(try travel([.drive]).accessibilityLabel, "1 drive")
        XCTAssertEqual(try travel([.subway, .bus]).accessibilityLabel, "2 rides: 1 subway, 1 bus")
        XCTAssertEqual(try travel([.walk, .subway]).accessibilityLabel, "1.2 miles walking")
        XCTAssertEqual(try travel([.walk], walkMiles: 1.0).accessibilityLabel, "1 mile walking")
    }

    func testDayCompleteLineUsesRidesWhenNobodyWalked() {
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.subway, .subway])), "2 subway rides")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.subway, .bus])), "1 subway, 1 bus")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.drive])), "1 drive")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.walk, .subway])), "1.2 mi walked")
    }
}
