import XCTest
@testable import Plandit

/// What the app does with a share once it opens (PRC-1 to PRC-4, PRC-7, PRC-8, SHR-3's deletion).
final class ShareProcessingTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ShareProcessingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    // MARK: - Fakes

    @MainActor private static let levain = PlaceCandidate(id: "test:levain", place: SampleData.levain, confidence: .high, reason: "test", estimatedCost: 6)
    @MainActor private static let tacos = PlaceCandidate(id: "test:tacos", place: SampleData.losTacos, confidence: .medium, reason: "test", estimatedCost: 12)

    /// Fails with a timeout the first `failures` times, then offers two places.
    @MainActor private final class FlakyExtractor: PlaceExtracting {
        var failures: Int
        private(set) var calls = 0
        init(failures: Int) { self.failures = failures }

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            calls += 1
            if calls <= failures { throw URLError(.timedOut) }
            return ExtractionResult(candidates: [ShareProcessingTests.levain, ShareProcessingTests.tacos])
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(candidates: [ShareProcessingTests.levain, ShareProcessingTests.tacos])
        }
    }

    @MainActor private final class QuotaExtractor: PlaceExtracting {
        private(set) var calls = 0
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            calls += 1
            throw DevelopmentSocialEvidenceError.dailyLimit
        }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }
    }

    /// Holds every lookup until released, and records how many ran at once.
    @MainActor private final class GatedExtractor: PlaceExtracting {
        private(set) var running = 0
        private(set) var mostAtOnce = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            await withCheckedContinuation { waiting.append($0) }
            running -= 1
            return ExtractionResult(candidates: [ShareProcessingTests.levain, ShareProcessingTests.tacos])
        }

        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult { ExtractionResult(candidates: []) }

        func releaseAll() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    @MainActor private struct AutoAddExtractor: PlaceExtracting {
        func extract(from url: URL, sharedText: String?) async throws -> ExtractionResult {
            ExtractionResult(candidates: [ShareProcessingTests.levain], autoConfirmedCandidateID: ShareProcessingTests.levain.id)
        }
        func resolve(evidence: String, platform: SourcePlatform) async throws -> ExtractionResult {
            ExtractionResult(candidates: [ShareProcessingTests.levain, ShareProcessingTests.tacos])
        }
    }

    /// Stands in for on-device OCR and speech.
    private struct FakeVideoReader: VideoEvidenceReading {
        var result: Result<String, VideoEvidenceError>
        func extract(from source: URL) async throws -> VideoEvidence {
            VideoEvidence(text: try result.get(), transcriptionNotice: nil)
        }
    }

    @MainActor private var mediaStore: TemporaryMediaStore {
        TemporaryMediaStore(root: directory.appending(path: "TemporaryMedia", directoryHint: .isDirectory))
    }

    @MainActor private func makeStore(
        saved: [SavedPost] = [],
        extractor: any PlaceExtracting,
        video: VideoEvidenceReading = FakeVideoReader(result: .success("Levain Bakery")),
        events: ((UsageEvent) -> Void)? = nil
    ) -> PlanditStore {
        PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: saved, profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: extractor,
            videoExtractor: video,
            mediaStore: mediaStore,
            extractionRetryDelay: .milliseconds(10),
            events: events
        )
    }

    /// A staged video, as the share extension leaves it, queued by name.
    @MainActor private func queueSharedVideo() throws -> URL {
        let source = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: source)
        let staged = try mediaStore.stage(source)
        ShareInbox.enqueue(IncomingShare(videoFileName: staged.lastPathComponent))
        return staged
    }

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func tiktok(_ n: Int) -> URL {
        URL(string: "https://www.tiktok.com/@nycbites/video/74000000000000003\(n)")!
    }

    // MARK: - PRC-1 several shares at once

    @MainActor func testSeveralSharesAreLookedUpAtTheSameTime() async throws {
        let extractor = GatedExtractor()
        let store = makeStore(extractor: extractor)
        for n in 1...3 { ShareInbox.enqueue(IncomingShare(url: tiktok(n))) }

        let ids = store.ingestPendingShares()
        XCTAssertEqual(ids.count, 3)
        try await waitUntil { extractor.running == 3 }
        XCTAssertEqual(extractor.mostAtOnce, 3, "All three lookups run side by side")
        XCTAssertEqual(store.saved.map(\.status), [.processing, .processing, .processing])

        extractor.releaseAll()
        try await waitUntil { store.saved.allSatisfy { $0.status == .needsConfirmation } }
        XCTAssertEqual(store.saved.map(\.status), [.needsConfirmation, .needsConfirmation, .needsConfirmation])
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testNoSharesMeansNothingToShow() {
        let store = makeStore(extractor: FlakyExtractor(failures: 0))
        XCTAssertEqual(store.ingestPendingShares(), [])
        let router = SheetRouter()
        let tab = router.tab
        router.showShares([])
        XCTAssertEqual(router.tab, tab)
        XCTAssertEqual(router.sharesShown, 0)
    }

    @MainActor func testOneShareOpensItsPostAndSeveralOpenSaved() {
        let router = SheetRouter()
        let one = UUID()
        router.showShares([one])
        XCTAssertEqual(router.tab, .saved)
        XCTAssertEqual(router.savedPath, [one])
        XCTAssertEqual(router.sharesShown, 1)

        router.showShares([UUID(), UUID()])
        XCTAssertEqual(router.tab, .saved)
        XCTAssertEqual(router.savedPath, [])
        XCTAssertEqual(router.sharesShown, 2)
    }

    // MARK: - PRC-3 one automatic retry

    @MainActor func testATimeoutIsRetriedOnceOnItsOwn() async throws {
        let extractor = FlakyExtractor(failures: 1)
        let store = makeStore(extractor: extractor)
        let id = try store.save(url: tiktok(1))

        try await waitUntil { store.post(id: id)?.status != .processing }
        XCTAssertEqual(extractor.calls, 2)
        XCTAssertEqual(store.post(id: id)?.status, .needsConfirmation)
        XCTAssertNil(store.post(id: id)?.failureMessage)
    }

    @MainActor func testTwoTimeoutsSayWeCouldntFindAPlace() async throws {
        let extractor = FlakyExtractor(failures: 5)
        let store = makeStore(extractor: extractor)
        let id = try store.save(url: tiktok(2))

        try await waitUntil { store.post(id: id)?.status != .processing }
        XCTAssertEqual(extractor.calls, 2, "Retried once, not more")
        XCTAssertEqual(store.post(id: id)?.status, .failed)
        XCTAssertEqual(store.post(id: id)?.failureMessage, PlanditStore.lookupFailedMessage)

        // Try again starts over, with its own retry.
        extractor.failures = 3
        store.retryExtraction(id)
        try await waitUntil { store.post(id: id)?.status != .processing }
        XCTAssertEqual(extractor.calls, 4)
        XCTAssertEqual(store.post(id: id)?.status, .needsConfirmation)
    }

    @MainActor func testDailyLimitIsNotRetried() async throws {
        let extractor = QuotaExtractor()
        let store = makeStore(extractor: extractor)
        let id = try store.save(url: tiktok(3))

        try await waitUntil { store.post(id: id)?.status != .processing }
        XCTAssertEqual(extractor.calls, 1)
        XCTAssertEqual(store.post(id: id)?.status, .needsEvidence)
    }

    // MARK: - PRC-4 shared videos

    @MainActor func testSharedVideoIsReadAndThenDeleted() async throws {
        var events: [UsageEvent] = []
        let store = makeStore(extractor: FlakyExtractor(failures: 0), events: { events.append($0) })
        let staged = try queueSharedVideo()

        let ids = store.ingestPendingShares()
        XCTAssertEqual(ids.count, 1)
        let id = try XCTUnwrap(ids.first)
        XCTAssertEqual(store.post(id: id)?.platform, .video)
        XCTAssertTrue(ShareInbox.pending().isEmpty)

        try await waitUntil { store.post(id: id)?.status != .processing }
        XCTAssertEqual(store.post(id: id)?.status, .needsConfirmation)
        XCTAssertEqual(store.post(id: id)?.candidates.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Deleted once it's read")
        XCTAssertEqual(events.filter { $0 == .linkSaved }.count, 1)
    }

    @MainActor func testUnreadableSharedVideoStaysAndAsksForThePlace() async throws {
        let store = makeStore(extractor: FlakyExtractor(failures: 0), video: FakeVideoReader(result: .failure(.noEvidence)))
        let staged = try queueSharedVideo()

        let id = try XCTUnwrap(store.ingestPendingShares().first)
        try await waitUntil { store.post(id: id)?.status != .processing }

        let post = try XCTUnwrap(store.post(id: id), "The post doesn't disappear")
        XCTAssertEqual(post.status, .needsEvidence)
        XCTAssertEqual(post.failureMessage, VideoEvidenceError.noEvidence.errorDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Deleted even when it couldn't be read")
    }

    @MainActor func testSharedVideoThatIsGoneAsksToShareItAgain() throws {
        let store = makeStore(extractor: FlakyExtractor(failures: 0))
        let staged = try queueSharedVideo()
        try FileManager.default.removeItem(at: staged)

        let id = try XCTUnwrap(store.ingestPendingShares().first)
        XCTAssertEqual(store.post(id: id)?.status, .needsEvidence)
        XCTAssertEqual(store.post(id: id)?.failureMessage, PlanditStore.shareVideoAgainMessage)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testSharedVideoNameCantReachOutsidePlanditsFolder() {
        XCTAssertNil(mediaStore.file(named: "../plandit-store.json"))
        XCTAssertNil(mediaStore.file(named: ".."))
        XCTAssertNil(mediaStore.file(named: ""))
        XCTAssertNotNil(mediaStore.file(named: "ABC.mov"))
    }

    @MainActor func testTryAgainOnAVideoPostSearchesWhatWasRead() async throws {
        let extractor = FlakyExtractor(failures: 0)
        let post = SavedPost(
            url: URL(string: "plandit-video://test")!, platform: .video, caption: "Levain Bakery",
            savedAt: .now, status: .failed, failureMessage: "We couldn't match those details."
        )
        let store = makeStore(saved: [post], extractor: extractor)

        store.retryExtraction(post.id)
        try await waitUntil { store.post(id: post.id)?.status != .processing }
        XCTAssertEqual(store.post(id: post.id)?.status, .needsConfirmation)
        XCTAssertEqual(extractor.calls, 0, "No link lookup for a video")
    }

    // MARK: - SHR-3 24-hour cleanup

    @MainActor func testUnreadVideosAreDeletedAfterADay() throws {
        let store = makeStore(extractor: FlakyExtractor(failures: 0))
        let staged = try queueSharedVideo()

        store.removeExpiredTemporaryMedia(now: Date(timeIntervalSinceNow: 23 * 3600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        store.removeExpiredTemporaryMedia(now: Date(timeIntervalSinceNow: 25 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        // The share still arrives, and asks for the video again.
        let id = try XCTUnwrap(store.ingestPendingShares().first)
        XCTAssertEqual(store.post(id: id)?.status, .needsEvidence)
    }

    // MARK: - PRC-7 success when a place is added

    @MainActor func testExactMatchAndPickBothCountAsAddedPlaces() async throws {
        let store = makeStore(extractor: AutoAddExtractor())
        let matched = try store.save(url: tiktok(4))
        try await waitUntil { store.post(id: matched)?.status == .ready }
        XCTAssertEqual(store.placesAdded, 1)

        let picked = SavedPost(url: tiktok(5), platform: .tiktok, savedAt: .now, status: .needsConfirmation, candidates: [Self.levain, Self.tacos])
        let pickStore = makeStore(saved: [picked], extractor: AutoAddExtractor())
        XCTAssertTrue(pickStore.confirm(postID: picked.id, candidateID: Self.tacos.id))
        XCTAssertEqual(pickStore.placesAdded, 1)
        XCTAssertTrue(pickStore.post(id: picked.id)?.isMappable == true, "It can go into today's plan")
    }

    // MARK: - PRC-8 a video post left processing

    @MainActor func testVideoPostLeftProcessingAsksForTheVideoAgainAtLaunch() async throws {
        let extractor = FlakyExtractor(failures: 0)
        let video = SavedPost(url: URL(string: "plandit-video://left")!, platform: .video, savedAt: .now, status: .processing)
        let link = SavedPost(url: tiktok(6), platform: .tiktok, savedAt: .now, status: .processing)
        let store = makeStore(saved: [video, link], extractor: extractor)

        XCTAssertEqual(store.post(id: video.id)?.status, .needsEvidence)
        XCTAssertEqual(store.post(id: video.id)?.failureMessage, PlanditStore.shareVideoAgainMessage)
        try await waitUntil { store.post(id: link.id)?.status != .processing }
        XCTAssertEqual(extractor.calls, 1, "Only the link is looked up again")
        XCTAssertEqual(store.post(id: link.id)?.status, .needsConfirmation)
    }

    @MainActor func testSyncDoesNotInterruptAVideoBeingRead() async throws {
        let store = makeStore(extractor: GatedExtractor())
        _ = try queueSharedVideo()
        let id = try XCTUnwrap(store.ingestPendingShares().first)

        // Another copy arrives (sync) while the video is still being read.
        store.replace(with: StoreSnapshot(saved: store.saved, today: store.today, profile: store.profile, pastPlans: [], visited: []))
        XCTAssertNotEqual(store.post(id: id)?.failureMessage, PlanditStore.shareVideoAgainMessage)
    }
}
