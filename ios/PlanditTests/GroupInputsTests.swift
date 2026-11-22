import XCTest
@testable import Plandit

/// Group plans, mode 2: friends' answers become the planner's inputs (GI-5, GI-6).
final class GroupInputsTests: XCTestCase {
    private let places = (0..<10).map { _ in UUID() }

    private func answer(_ name: String, budget: Int, _ from: Int, _ until: Int, stars: [UUID] = []) -> GroupAnswer {
        let at = Date(timeIntervalSince1970: 1_795_000_000)
        return GroupAnswer(id: UUID(), name: name, budget: budget, freeFrom: ClockTime(from), freeUntil: ClockTime(until),
                           stars: stars, createdAt: at, updatedAt: at)
    }

    /// The organizer as GI-5 has them by default: their own budget and the whole range, 12 to 8 PM.
    private func organizer(budget: Double = 60, _ from: Int = 12, _ until: Int = 20) -> GroupInputs.Person {
        GroupInputs.Person(member: .organizer, budget: budget, from: ClockTime(from), until: ClockTime(until), stars: [])
    }

    private func ready(_ result: GroupInputs.Result, file: StaticString = #filePath, line: UInt = #line) -> GroupInputs.Plan? {
        guard case .ready(let plan) = result else {
            XCTFail("expected a plan, got \(result)", file: file, line: line)
            return nil
        }
        return plan
    }

    // MARK: - GI-5

    @MainActor func testEveryonesFreeTimeAndTheLowestBudget() {
        // The verification table's case: budgets 20, 40, 60; windows 12–6, 2–8, 1–5.
        let answers = [answer("Maya", budget: 20, 12, 18), answer("Jordan", budget: 40, 14, 20), answer("Sam", budget: 60, 13, 17)]
        guard let plan = ready(GroupInputs.combine(answers: answers, organizer: organizer(), places: places)) else { return }
        XCTAssertEqual(plan.start, ClockTime(14))
        XCTAssertEqual(plan.end, ClockTime(17))
        XCTAssertEqual(plan.budget, 20)
    }

    @MainActor func testTheOrganizersOwnBudgetAndTimesCount() {
        let answers = [answer("Maya", budget: 40, 12, 18)]
        guard let plan = ready(GroupInputs.combine(answers: answers, organizer: organizer(budget: 25, 13, 16), places: places)) else { return }
        XCTAssertEqual(plan.budget, 25)
        XCTAssertEqual(plan.start, ClockTime(13))
        XCTAssertEqual(plan.end, ClockTime(16))
    }

    @MainActor func testWithNoAnswersTheOrganizersInputsAreTheirs() {
        guard let plan = ready(GroupInputs.combine(answers: [], organizer: organizer(budget: 30), places: Array(places.prefix(3)))) else { return }
        XCTAssertEqual(plan.start, ClockTime(12))
        XCTAssertEqual(plan.end, ClockTime(20))
        XCTAssertEqual(plan.budget, 30)
        XCTAssertEqual(plan.candidates.map(\.placeID), Array(places.prefix(3)))
        XCTAssertEqual(plan.candidates.map(\.stars), [0, 0, 0])
    }

    @MainActor func testTheMostStarredPlacesComeFirstCappedAtSeven() {
        let answers = [
            answer("Maya", budget: 20, 12, 18, stars: [places[9], places[4], places[2]]),
            answer("Jordan", budget: 40, 12, 18, stars: [places[9], places[4]]),
            answer("Sam", budget: 60, 12, 18, stars: [places[9], places[7]]),
        ]
        guard let plan = ready(GroupInputs.combine(answers: answers, organizer: organizer(), places: places)) else { return }
        XCTAssertEqual(plan.candidates.count, GroupInputs.maxCandidates)
        // 3 stars, 2, then 1 each in the organizer's order, then unstarred in the organizer's order.
        XCTAssertEqual(plan.candidates.map(\.placeID), [places[9], places[4], places[2], places[7], places[0], places[1], places[3]])
        XCTAssertEqual(plan.candidates.map(\.stars), [3, 2, 1, 1, 0, 0, 0])
    }

    @MainActor func testStarsOutsideTheRequestOrRepeatedAreIgnored() {
        let stranger = UUID()
        let answers = [answer("Maya", budget: 20, 12, 18, stars: [stranger, places[1], places[1]])]
        guard let plan = ready(GroupInputs.combine(answers: answers, organizer: organizer(), places: Array(places.prefix(2)))) else { return }
        XCTAssertEqual(plan.candidates.map(\.placeID), [places[1], places[0]])
        XCTAssertEqual(plan.candidates.map(\.stars), [1, 0])
    }

    // MARK: - GI-6

    @MainActor func testClash() {
        // The verification table's case: 12–2 and 4–6 don't overlap; both are named, the organizer
        // (free all day) isn't.
        let maya = answer("Maya", budget: 20, 12, 14), jordan = answer("Jordan", budget: 40, 16, 18)
        let result = GroupInputs.combine(answers: [maya, jordan], organizer: organizer(), places: places)
        XCTAssertEqual(result, .clash([.friend(maya.id), .friend(jordan.id)]))
    }

    @MainActor func testLeavingSomeoneOutGivesAPlan() {
        let maya = answer("Maya", budget: 20, 12, 14), jordan = answer("Jordan", budget: 40, 16, 18)
        let result = GroupInputs.combine(answers: [maya, jordan], organizer: organizer(), places: places, leftOut: [.friend(maya.id)])
        guard let plan = ready(result) else { return }
        XCTAssertEqual(plan.start, ClockTime(16))
        XCTAssertEqual(plan.end, ClockTime(18))
        // Only Maya's times are left out: the plan still fits her budget.
        XCTAssertEqual(plan.budget, 20)
    }

    @MainActor func testOnlyThePeopleOutsideTheBiggestGroupAreNamed() {
        let maya = answer("Maya", budget: 20, 12, 17), jordan = answer("Jordan", budget: 40, 13, 17)
        let sam = answer("Sam", budget: 60, 17, 20)
        XCTAssertEqual(GroupInputs.combine(answers: [maya, jordan, sam], organizer: organizer(), places: places), .clash([.friend(sam.id)]))
    }

    @MainActor func testAnHourIsEnoughAndLessIsAClash() {
        let maya = answer("Maya", budget: 20, 12, 15)
        let hour = answer("Jordan", budget: 40, 14, 18)
        guard let plan = ready(GroupInputs.combine(answers: [maya, hour], organizer: organizer(), places: places)) else { return }
        XCTAssertEqual(plan.start, ClockTime(14))
        XCTAssertEqual(plan.end, ClockTime(15))

        let short = GroupAnswer(id: UUID(), name: "Sam", budget: 40, freeFrom: ClockTime(14, 5), freeUntil: ClockTime(18),
                                stars: [], createdAt: .now, updatedAt: .now)
        XCTAssertEqual(GroupInputs.combine(answers: [maya, short], organizer: organizer(), places: places),
                       .clash([.friend(maya.id), .friend(short.id)]))
    }

    @MainActor func testAWindowShorterThanAnHourIsNamedAlone() {
        let maya = answer("Maya", budget: 20, 12, 18)
        let brief = GroupAnswer(id: UUID(), name: "Sam", budget: 40, freeFrom: ClockTime(13), freeUntil: ClockTime(13, 30),
                                stars: [], createdAt: .now, updatedAt: .now)
        XCTAssertEqual(GroupInputs.combine(answers: [maya, brief], organizer: organizer(), places: places), .clash([.friend(brief.id)]))
    }

    @MainActor func testTheOrganizerIsNamedWhenTheirOwnTimesClash() {
        let maya = answer("Maya", budget: 20, 16, 18)
        XCTAssertEqual(GroupInputs.combine(answers: [maya], organizer: organizer(12, 13), places: places),
                       .clash([.organizer, .friend(maya.id)]))
    }

    @MainActor func testTheOrganizerCantBeLeftOut() {
        let maya = answer("Maya", budget: 20, 16, 18)
        XCTAssertEqual(GroupInputs.combine(answers: [maya], organizer: organizer(12, 13), places: places, leftOut: [.organizer]),
                       .clash([.organizer, .friend(maya.id)]))
        guard let plan = ready(GroupInputs.combine(answers: [maya], organizer: organizer(12, 13), places: places, leftOut: [.friend(maya.id)])) else { return }
        XCTAssertEqual(plan.start, ClockTime(12))
        XCTAssertEqual(plan.end, ClockTime(13))
    }
}
