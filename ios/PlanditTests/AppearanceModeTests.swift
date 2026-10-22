import XCTest
@testable import Plandit

@MainActor
final class AppearanceModeTests: XCTestCase {
    func testMissingValueResolvesToSystem() {
        XCTAssertEqual(AppearanceMode.resolve(nil), .system)
    }

    func testKnownValuesResolveToMatchingModes() {
        XCTAssertEqual(AppearanceMode.resolve("system"), .system)
        XCTAssertEqual(AppearanceMode.resolve("light"), .light)
        XCTAssertEqual(AppearanceMode.resolve("dark"), .dark)
    }

    func testUnknownValueResolvesToSystem() {
        XCTAssertEqual(AppearanceMode.resolve("midnight"), .system)
    }

    func testColorSchemeMapping() {
        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)
    }

    func testAppearanceSettingsPersistsChanges() {
        let suiteName = "AppearanceModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppearanceSettings(defaults: defaults)
        settings.mode = .light

        XCTAssertEqual(defaults.string(forKey: AppearanceMode.storageKey), AppearanceMode.light.rawValue)
    }
}
