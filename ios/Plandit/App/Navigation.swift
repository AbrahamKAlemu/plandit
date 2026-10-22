import Observation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case today, saved, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .saved: "Saved"
        case .profile: "Profile"
        }
    }

    /// Launch with `-startTab saved` (or `profile`) to open on another tab; handy for screenshots and UI tests.
    static var launchTab: AppTab {
        UserDefaults.standard.string(forKey: "startTab").flatMap(AppTab.init(rawValue:)) ?? .today
    }

    var icon: Lucide {
        switch self {
        case .today: .route
        case .saved: .bookmark
        case .profile: .userRound
        }
    }
}

/// Navigation inside the persistent sheet. Each tab keeps its own stack, like Find My.
@Observable
final class SheetRouter {
    var todayPath: [UUID] = []
    var savedPath: [UUID] = []

    func selection(in tab: AppTab) -> UUID? {
        switch tab {
        case .today: todayPath.last
        case .saved: savedPath.last
        case .profile: nil
        }
    }
}

/// Detents for the always-on sheet: a peek that shows the header + tab bar, half, and full.
enum SheetDetent {
    static let peekHeight: CGFloat = 178
    static let peek = PresentationDetent.height(peekHeight)
    static let all: Set<PresentationDetent> = [peek, .medium, .large]

    /// Launch with `-startDetent peek` or `large` to open the sheet at another height.
    static var launchDetent: PresentationDetent {
        switch UserDefaults.standard.string(forKey: "startDetent") {
        case "peek": peek
        case "large": .large
        default: .medium
        }
    }

    /// How much of the map the sheet covers, so the camera can frame content above it.
    static func coveredHeight(_ detent: PresentationDetent, screenHeight: CGFloat) -> CGFloat {
        detent == peek ? peekHeight + Space.md : screenHeight * 0.52 + Space.md
    }
}
