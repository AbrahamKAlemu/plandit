import XCTest
@testable import Plandit

/// Today's summary tile for getting around: miles walked, or the rides when nobody walks.
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

    func testSubwayOnlyDayCountsSubwayRides() {
        let travel = TodaySummaryText.travel(day([.subway, .subway]))
        XCTAssertEqual(travel.value, "2 subway rides")
        XCTAssertEqual(travel.caption, "Getting around")
        XCTAssertEqual(travel.icon, .trainFront)

        XCTAssertEqual(TodaySummaryText.travel(day([.subway])).value, "1 subway ride")
    }

    func testBusOnlyDayCountsBusRides() {
        let travel = TodaySummaryText.travel(day([.bus]))
        XCTAssertEqual(travel.value, "1 bus ride")
        XCTAssertEqual(travel.icon, .bus)
        XCTAssertEqual(TodaySummaryText.travel(day([.bus, .bus, .bus])).value, "3 bus rides")
    }

    func testMixedTransitNamesEachKind() {
        XCTAssertEqual(TodaySummaryText.travel(day([.subway, .bus])).value, "1 subway, 1 bus")
        XCTAssertEqual(TodaySummaryText.travel(day([.bus, .subway, .subway])).value, "2 subway, 1 bus")
    }

    func testDriveOnlyDayCountsDrives() {
        let travel = TodaySummaryText.travel(day([.drive]))
        XCTAssertEqual(travel.value, "1 drive")
        XCTAssertEqual(travel.icon, .car)
        XCTAssertEqual(TodaySummaryText.travel(day([.drive, .drive])).value, "2 drives")
        XCTAssertEqual(TodaySummaryText.travel(day([.subway, .drive])).value, "1 subway, 1 drive")
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
            XCTAssertNotEqual(TodaySummaryText.travel(day(modes)).value, "0.0 mi", "\(modes)")
        }
    }

    func testDayCompleteLineUsesRidesWhenNobodyWalked() {
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.subway, .subway])), "2 subway rides")
        XCTAssertEqual(TodaySummaryText.completedTravel(day([.walk, .subway])), "1.2 mi walked")
    }
}
