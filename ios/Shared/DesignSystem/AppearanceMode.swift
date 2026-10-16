import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "plandit.appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static func resolve(_ rawValue: String?) -> AppearanceMode {
        rawValue.flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    static var saved: AppearanceMode {
        resolve(AppGroup.defaults.string(forKey: storageKey))
    }
}

@Observable
@MainActor
final class AppearanceSettings {
    private let defaults: UserDefaults

    var mode: AppearanceMode {
        didSet {
            defaults.set(mode.rawValue, forKey: AppearanceMode.storageKey)
        }
    }

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        mode = AppearanceMode.resolve(defaults.string(forKey: AppearanceMode.storageKey))
    }
}
