import XCTest
@testable import Plandit

/// Slice B review findings, each turned from the reviewer's probe into a test of the fixed
/// behavior. Every one of these failed before its fix.
final class ShareReviewRegressionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ShareReviewRegressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await MainActor.run { Self.clearInbox() }
    }

    override func tearDown() async throws {
        await MainActor.run { Self.clearInbox() }
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor private static func clearInbox() {
        for share in ShareInbox.pending() { ShareInbox.acknowledge(share.id) }
    }

    @MainActor private var mediaStore: TemporaryMediaStore {
        TemporaryMediaStore(root: directory.appending(path: "TemporaryMedia", directoryHint: .isDirectory))
    }

    /// Every file under the media folder, wherever a read has moved it.
    @MainActor private func mediaFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: mediaStore.root, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private final class TimeoutProvider: SocialMetadataProviding, @unchecked Sendable {
        var calls = 0
        func metadata(for url: URL) async throws -> SocialMetadata? {
            calls += 1
            throw URLError(.timedOut)
        }
    }

    private struct FailingProvider: SocialMetadataProviding {
        let code: URLError.Code
        func metadata(for url: URL) async throws -> SocialMetadata? { throw URLError(code) }
    }

    private struct NilProvider: SocialMetadataProviding {
        func metadata(for url: URL) async throws -> SocialMetadata? { nil }
    }

    /// Holds a video read open until the test lets it finish.
    private final class GatedVideoReader: VideoEvidenceReading, @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        func extract(from source: URL) async throws -> VideoEvidence {
            await withCheckedContinuation { continuation = $0 }
            return VideoEvidence(text: "Levain Bakery", transcriptionNotice: nil)
        }
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor private func store(extractor: any PlaceExtracting, video: any VideoEvidenceReading) -> PlanditStore {
        PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: [], profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: extractor, videoExtractor: video, mediaStore: mediaStore,
            extractionRetryDelay: .milliseconds(10)
        )
    }

    @MainActor private func stageSharedVideo() throws -> IncomingShare {
        let source = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: source)
        let staged = try mediaStore.stage(source)
        let share = IncomingShare(videoFileName: staged.lastPathComponent)
        ShareInbox.enqueue(share)
        return share
    }

    // MARK: - PRC-3 in production (must-fix 2)

    /// Render asleep: the backend times out on an Instagram link shared without text. One retry,
    /// then "We couldn't find a place" with Try again, not a silent "Add the place".
    @MainActor func testBackendTimeoutIsRetriedOnceThenSaysWeCouldntFindAPlace() async throws {
        let primary = TimeoutProvider()
        let extractor = FixturePlaceExtractor(
            metadataProvider: FallbackSocialMetadataProvider(primary: primary, fallback: NilProvider()),
            placeSearcher: nil
        )
        let s = store(extractor: extractor, video: GatedVideoReader())
        let id = try s.save(url: URL(string: "https://www.instagram.com/reel/DHZYjjnPKez/")!)
        try await waitUntil { s.post(id: id)?.status != .processing }

        XCTAssertEqual(primary.calls, 2, "tried, then retried once")
        XCTAssertEqual(s.post(id: id)?.status, .failed)
        XCTAssertEqual(s.post(id: id)?.failureMessage, PlanditStore.lookupFailedMessage)
    }

    /// The backend is unreachable, for TikTok and Instagram alike, timed out or offline: the
    /// extractor says so instead of returning no places, so the store can retry.
    @MainActor func testUnreachableBackendThrowsForTikTokAndInstagram() async throws {
        let links = [
            URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!,
            URL(string: "https://www.instagram.com/reel/DHZYjjnPKez/")!,
        ]
        for code in [URLError.Code.timedOut, .notConnectedToInternet] {
            for url in links {
                let extractor = FixturePlaceExtractor(
                    metadataProvider: FallbackSocialMetadataProvider(primary: FailingProvider(code: code), fallback: NilProvider()),
                    placeSearcher: nil
                )
                do {
                    _ = try await extractor.extract(from: url, sharedText: nil)
                    XCTFail("\(code.rawValue) on \(url.host() ?? "") should throw")
                } catch let error as URLError {
                    XCTAssertEqual(error.code, code)
                }
            }
        }
    }

    /// With the caption from the share there's still something to search, so no error.
    @MainActor func testUnreachableBackendWithSharedTextStillSearchesTheText() async throws {
        let extractor = FixturePlaceExtractor(
            metadataProvider: FallbackSocialMetadataProvider(primary: FailingProvider(code: .timedOut), fallback: NilProvider()),
            placeSearcher: nil
        )
        let result = try await extractor.extract(
            from: URL(string: "https://www.instagram.com/reel/DHZYjjnPKez/")!,
            sharedText: "The cookies at Levain Bakery are worth the line"
        )
        XCTAssertEqual(result.candidates.first?.place.name, SampleData.levain.name)
    }

    /// TikTok offline, through the store: one retry, then "We couldn't find a place".
    @MainActor func testOfflineTikTokSaysWeCouldntFindAPlace() async throws {
        let extractor = FixturePlaceExtractor(
            metadataProvider: FallbackSocialMetadataProvider(
                primary: FailingProvider(code: .notConnectedToInternet),
                fallback: FailingProvider(code: .notConnectedToInternet)
            ),
            placeSearcher: nil
        )
        let s = store(extractor: extractor, video: GatedVideoReader())
        let id = try s.save(url: URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!)
        try await waitUntil { s.post(id: id)?.status != .processing }
        XCTAssertEqual(s.post(id: id)?.status, .failed)
        XCTAssertEqual(s.post(id: id)?.failureMessage, PlanditStore.lookupFailedMessage)
    }

    // MARK: - Cleanup carries on past a file it can't delete (nice-to-have 5)

    /// One expired video can't be deleted (it's locked): the rest still go, and nothing asserts.
    @MainActor func testCleanupCarriesOnPastAFileItCantDelete() throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        try FileManager.default.createDirectory(at: mediaStore.root, withIntermediateDirectories: true)
        let locked = mediaStore.root.appending(path: "locked.mov")
        try Data(count: 8).write(to: locked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        for n in 0..<6 {
            try Data(count: 8).write(to: mediaStore.root.appending(path: "clip-\(n).mov"))
        }

        s.removeExpiredTemporaryMedia(now: Date(timeIntervalSinceNow: 25 * 3600))

        XCTAssertEqual(mediaFiles().map(\.lastPathComponent), ["locked.mov"])
    }
}
