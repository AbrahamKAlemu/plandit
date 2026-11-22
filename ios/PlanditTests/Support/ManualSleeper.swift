import Foundation
import XCTest

/// A clock the test moves by hand: `sleep` waits until `advance` passes its deadline. A cancelled
/// sleep ends at once with `CancellationError`, as `Task.sleep` does.
final class ManualSleeper: @unchecked Sendable {
    private struct Waiter {
        var deadline: Duration
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var now: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    private var asked: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    asked.append(duration)
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = Waiter(deadline: now + duration, continuation: continuation)
                    }
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on and wakes every sleep that's due.
    func advance(by duration: Duration) {
        let due = lock.withLock {
            now += duration
            let due = waiters.filter { $0.value.deadline <= now }
            for id in due.keys { waiters.removeValue(forKey: id) }
            return due.values.sorted { $0.deadline < $1.deadline }
        }
        for waiter in due { waiter.continuation.resume() }
    }

    /// How many sleeps are waiting.
    var sleeping: Int { lock.withLock { waiters.count } }
    /// Every sleep asked for, in order.
    var requested: [Duration] { lock.withLock { asked } }
}

/// Waits (for real, briefly) until `condition` holds, failing after `timeout`.
@MainActor
func eventually(_ what: String = "condition", timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
                _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

/// Lets queued work run: a few real turns of the main actor.
@MainActor
func settle(_ turns: Int = 20) async {
    for _ in 0..<turns {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}
