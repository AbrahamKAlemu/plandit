import XCTest
@testable import Plandit

/// The bottom bar's tabs and the `-startTab` launch argument (NAV-2, D-2).
final class NavigationTests: XCTestCase {
    @MainActor func testTabsAreTodaySavedAndProfile() {
        XCTAssertEqual(AppTab.allCases, [.today, .saved, .profile])
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Today", "Saved", "Profile"])
    }

    @MainActor func testLaunchValueSettingsOpensProfile() {
        XCTAssertEqual(AppTab(launchValue: "settings"), .profile, "1.0's Settings tab now lives in Profile")
        XCTAssertEqual(AppTab(launchValue: "saved"), .saved)
        XCTAssertEqual(AppTab(launchValue: "profile"), .profile)
        XCTAssertEqual(AppTab(launchValue: nil), .today)
        XCTAssertEqual(AppTab(launchValue: "nonsense"), .today)
    }
}

/// The sheet's body follows its height, so it shows while the sheet is still being dragged up.
@MainActor
final class SheetRevealTests: XCTestCase {
    func testHiddenAtThePeek() {
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: SheetDetent.peekHeight), 0)
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: SheetDetent.peekHeight + SheetDetent.revealStart), 0)
    }

    func testFadesInOverTheFirstStretchAboveThePeek() {
        let halfway = SheetDetent.peekHeight + SheetDetent.revealStart + SheetDetent.revealDistance / 2
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: halfway), 0.5, accuracy: 0.001)
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: SheetDetent.peekHeight + 80), 1)
    }

    func testFullyShownAtHalfAndFullHeight() {
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: 436), 1)
        XCTAssertEqual(SheetDetent.reveal(sheetHeight: 800), 1)
    }
}

/// The line under "Profile" describes the map behind it.
@MainActor
final class ProfileSubtitleTests: XCTestCase {
    func testCountsVisitedPlacesAndPlans() {
        XCTAssertEqual(ProfileSheet.subtitle(visited: 19, plans: 6), "19 places visited · 6 plans completed")
        XCTAssertEqual(ProfileSheet.subtitle(visited: 1, plans: 1), "1 place visited · 1 plan completed")
    }

    func testLeavesOutAZeroCount() {
        XCTAssertEqual(ProfileSheet.subtitle(visited: 0, plans: 2), "2 plans completed")
    }

    func testSaysWhatWillAppearWhenThereIsNothingYet() {
        XCTAssertEqual(ProfileSheet.subtitle(visited: 0, plans: 0), "Complete a plan to see it on the map")
    }
}
