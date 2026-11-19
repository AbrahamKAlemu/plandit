import XCTest
@testable import Plandit

/// One way to count trips in words, shared by Today's summary and the Budget sheet.
@MainActor final class RideWordingTests: XCTestCase {
    private func legs(_ modes: [TravelMode]) -> [TravelLeg] {
        modes.map { TravelLeg.estimate($0, miles: 1.2, fromStopID: UUID(), toStopID: UUID()) }
    }

    func testSingleAndPluralForEachKind() {
        XCTAssertEqual(RideWording.count(1, .subway), "1 subway ride")
        XCTAssertEqual(RideWording.count(2, .subway), "2 subway rides")
        XCTAssertEqual(RideWording.count(1, .bus), "1 bus ride")
        XCTAssertEqual(RideWording.count(2, .bus), "2 bus rides")
        XCTAssertEqual(RideWording.count(1, .drive), "1 drive")
        XCTAssertEqual(RideWording.count(2, .drive), "2 drives")
        XCTAssertEqual(RideWording.count(1, .walk), "1 walk")
        XCTAssertEqual(RideWording.count(3, .walk), "3 walks")
    }

    func testEachKindInAList() {
        XCTAssertEqual(RideWording.kind(1, .subway), "1 subway")
        XCTAssertEqual(RideWording.kind(2, .subway), "2 subway")
        XCTAssertEqual(RideWording.kind(1, .bus), "1 bus")
        XCTAssertEqual(RideWording.kind(2, .bus), "2 bus")
        XCTAssertEqual(RideWording.kind(1, .drive), "1 drive")
        XCTAssertEqual(RideWording.kind(2, .drive), "2 drives")
    }

    func testMixedKindsGoSubwayBusDriveAndCountDrivesProperly() {
        XCTAssertEqual(RideWording.kinds(legs([.subway, .bus, .drive, .drive, .bus])), "1 subway, 2 bus, 2 drives")
        XCTAssertEqual(RideWording.kinds(legs([.drive, .walk, .subway])), "1 subway, 1 drive", "walks aren't rides")
    }

    func testTodayAndBudgetSayTheSameThing() {
        let mixed = legs([.subway, .bus, .drive, .drive, .bus])
        let plan = day(mixed)
        XCTAssertEqual(TodaySummaryText.travel(plan).caption, "1 subway, 2 bus, 2 drives")
        XCTAssertEqual(TodaySummaryText.travel(plan).value, "5 rides")

        XCTAssertEqual(BudgetSheet.transitText(mixed.filter(\.mode.isTransit)), "3 rides: 1 subway, 2 bus")
        XCTAssertEqual(BudgetSheet.transitText(legs([.subway, .subway])), RideWording.count(2, .subway))
        XCTAssertEqual(BudgetSheet.transitText(legs([.bus])), RideWording.count(1, .bus))
    }

    /// Stops two hours apart joined by these trips.
    private func day(_ legs: [TravelLeg]) -> DayPlan {
        let places = [SampleData.met, SampleData.highLine, SampleData.losTacos, SampleData.washingtonSquare, SampleData.joesPizza, SampleData.met]
        let stops = places.prefix(legs.count + 1).enumerated().map { index, place in
            PlanStop(place: place, start: SampleData.at(9 + index * 2), durationMinutes: 60, estimatedCost: 0, status: .upcoming)
        }
        let joined = zip(zip(stops, stops.dropFirst()), legs).map { pair, leg in
            TravelLeg.estimate(leg.mode, miles: 1.2, fromStopID: pair.0.id, toStopID: pair.1.id)
        }
        return DayPlan(date: .now, title: "Today", budget: 60, stops: Array(stops), legs: joined)
    }
}
