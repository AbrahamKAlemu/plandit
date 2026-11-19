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
