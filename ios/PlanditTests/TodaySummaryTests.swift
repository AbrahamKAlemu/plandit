import XCTest
@testable import Plandit

/// Today's summary tile for getting around: miles walked, or the rides when nobody walks.
/// The tile is a value over a caption, so "2 subway rides" shows as "2" over "subway rides".
@MainActor final class TodaySummaryTests: XCTestCase {
    /// A day of `modes.count + 1` stops joined by trips made these ways.
    private func day(_ modes: [TravelMode]) -> DayPlan {
        let places = [SampleData.met, SampleData.highLine, SampleData.losTacos, SampleData.washingtonSquare, SampleData.joesPizza]
        let stops = places.prefix(modes.count + 1).enumerated().map { index, place in
            PlanStop(place: place, start: SampleData.at(10 + index * 2), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        }
        let legs = zip(zip(stops, stops.dropFirst()), modes).map { pair, mode in
            TravelLeg.estimate(mode, miles: 1.2, fromStopID: pair.0.id, toStopID: pair.1.id)
        }
        return DayPlan(date: .now, title: "Today", budget: 60, stops: Array(stops), legs: legs)
    }

    /// What the tile reads as one line.
    private func tile(_ modes: [TravelMode]) -> String {
        let travel = TodaySummaryText.travel(day(modes))
        return "\(travel.value) \(travel.caption)"
    }

    func testSubwayOnlyDayCountsSubwayRides() {
        let travel = TodaySummaryText.travel(day([.subway, .subway]))
        XCTAssertEqual(travel.value, "2")
        XCTAssertEqual(travel.caption, "subway rides")
        XCTAssertEqual(travel.icon, .trainFront)
        XCTAssertEqual(tile([.subway, .subway]), "2 subway rides")
        XCTAssertEqual(tile([.subway]), "1 subway ride")
    }

    func testBusOnlyDayCountsBusRides() {
        XCTAssertEqual(tile([.bus]), "1 bus ride")
        XCTAssertEqual(TodaySummaryText.travel(day([.bus])).icon, .bus)
        XCTAssertEqual(tile([.bus, .bus, .bus]), "3 bus rides")
    }

    func testMixedTransitNamesEachKind() {
        let travel = TodaySummaryText.travel(day([.subway, .bus]))
        XCTAssertEqual(travel.value, "2 rides")
        XCTAssertEqual(travel.caption, "1 subway, 1 bus")
        XCTAssertEqual(travel.icon, .trainFront, "ties go to the subway")
        XCTAssertEqual(TodaySummaryText.travel(day([.bus, .subway, .subway])).caption, "2 subway, 1 bus")
        XCTAssertEqual(TodaySummaryText.travel(day([.bus, .bus, .subway])).icon, .bus, "the icon follows the most common kind")
    }

    func testDriveOnlyDayCountsDrives() {
        XCTAssertEqual(tile([.drive]), "1 drive")
        XCTAssertEqual(TodaySummaryText.travel(day([.drive])).icon, .car)
        XCTAssertEqual(tile([.drive, .drive]), "2 drives")
        XCTAssertEqual(TodaySummaryText.travel(day([.subway, .drive])).caption, "1 subway, 1 drive")
    }

    func testWalkingPlusTransitKeepsMilesWalked() {
        let plan = day([.walk, .subway])
        let travel = TodaySummaryText.travel(plan)
        XCTAssertEqual(travel.value, plan.walkingMiles.milesText)
        XCTAssertEqual(travel.value, "1.2 mi")
        XCTAssertEqual(travel.caption, "Walking")
        XCTAssertEqual(travel.icon, .footprints)
    }

    func testNeverSaysZeroMilesWalkingOnADayWithRides() {
        for modes in [[TravelMode.subway], [.bus], [.drive], [.subway, .bus, .drive]] {
            let travel = TodaySummaryText.travel(day(modes))
            XCTAssertNotEqual(travel.value, "0.0 mi", "\(modes)")
            XCTAssertNotEqual(travel.caption, "Walking", "\(modes)")
        }
    }

    func testDayCompleteLineUsesRidesWhenNobodyWalked() {
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.subway, .subway])), "2 subway rides")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.subway, .bus])), "1 subway, 1 bus")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.drive])), "1 drive")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.walk, .subway])), "1.2 mi walked")
    }
}
