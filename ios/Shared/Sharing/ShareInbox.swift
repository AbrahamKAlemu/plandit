import Foundation

/// The App Group shared by the app and the share extension.
/// Change it here and in project.yml (both entitlements blocks) together.
enum AppGroup {
    static let identifier = "group.com.plandit.app"

    /// Falls back to standard defaults when the entitlement is missing (e.g. unsigned simulator builds),
    /// which keeps the app working but stops shares from reaching it. Shared identity is required
    /// so every `@AppStorage` observer receives the same live change notification.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: identifier) ?? .standard
}

/// A link someone shared into Plandit from TikTok, Instagram, or any app's share sheet.
struct IncomingShare: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var sharedText: String?
    var receivedAt = Date()
}

/// Hand-off queue: the share extension enqueues, and the app acknowledges only after durable import.
enum ShareInbox {
    private static let key = "plandit.pendingShares"

    static func enqueue(_ share: IncomingShare) {
        var queue = pending()
        guard !queue.contains(where: { $0.url == share.url }) else { return }
        queue.append(share)
        AppGroup.defaults.set(try? JSONEncoder().encode(queue), forKey: key)
    }

    static func pending() -> [IncomingShare] {
        guard let data = AppGroup.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IncomingShare].self, from: data)) ?? []
    }

    static func acknowledge(_ id: UUID) {
        let queue = pending().filter { $0.id != id }
        if queue.isEmpty {
            AppGroup.defaults.removeObject(forKey: key)
        } else {
            AppGroup.defaults.set(try? JSONEncoder().encode(queue), forKey: key)
        }
    }
}
