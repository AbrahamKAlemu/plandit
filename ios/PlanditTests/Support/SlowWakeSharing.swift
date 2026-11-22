import Foundation
@testable import Plandit

/// A server that is slow to wake: while `holds` is on, each publish waits for `release()`. With
/// `failsOnRelease`, the held publish then fails instead (the server never answered).
@MainActor final class SlowWakeSharing: PlanSharing {
    private(set) var published: [SharedPlanPayload] = []
    private var waiting: CheckedContinuation<Void, Never>?
    var holds = true
    var failsOnRelease = false
    var isHolding: Bool { waiting != nil }

    func release() {
        holds = false
        waiting?.resume()
        waiting = nil
    }

    func publish(_ payload: SharedPlanPayload) async throws -> (slug: String, url: URL) {
        if holds {
            await withCheckedContinuation { waiting = $0 }
            if failsOnRelease {
                failsOnRelease = false
                throw APIError.network
            }
        }
        published.append(payload)
        return ("test123abc", URL(string: "https://plandit.app/p/test123abc")!)
    }

    func unpublish(slug: String) async throws {}

    /// Waits until a publish is held, up to two seconds.
    func waitUntilHolding() async throws {
        for _ in 0..<200 {
            if isHolding { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
