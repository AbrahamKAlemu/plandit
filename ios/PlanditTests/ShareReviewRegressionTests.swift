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

    // MARK: - Cleanup during a read (nice-to-have 4)

    /// A shared video staged almost a day ago is being read when the 24-hour cleanup runs (in the
    /// app, or in the share extension's process): the read keeps its file.
    @MainActor func testCleanupLeavesAVideoBeingReadAlone() async throws {
        let reader = GatedVideoReader()
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: reader)
        _ = try stageSharedVideo()
        _ = try XCTUnwrap(s.ingestPendingShares().first)
        try await waitUntil { reader.continuation != nil }

        s.removeExpiredTemporaryMedia(now: Date(timeIntervalSinceNow: 25 * 3600))

        XCTAssertEqual(mediaFiles().count, 1, "the video being read is still there")
        reader.continuation?.resume()
        try await waitUntil { self.mediaFiles().isEmpty }
        XCTAssertTrue(mediaFiles().isEmpty, "and is deleted once read")
    }

    /// A read the app never finished (it quit mid-read) leaves its file in `Reading/`: it goes
    /// after 48 hours, not 24.
    @MainActor func testAnAbandonedReadIsDeletedAfterTwoDays() throws {
        let source = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: source)
        let reading = try mediaStore.claimForReading(try mediaStore.stage(source))

        mediaStore.removeExpiredFiles(now: Date(timeIntervalSinceNow: 25 * 3600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reading.path))

        mediaStore.removeExpiredFiles(now: Date(timeIntervalSinceNow: 49 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reading.path))
    }

    // MARK: - Raw errors in synced messages (nice-to-have 6)

    /// The video goes missing mid-read: the post asks for it again, not "The file … couldn't be opened".
    @MainActor func testAVideoThatVanishesAsksForItAgainWithoutASystemError() async throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil),
                      video: VideoEvidenceExtractor(mediaStore: mediaStore))
        _ = try stageSharedVideo()
        let id = try XCTUnwrap(s.ingestPendingShares().first)
        for file in mediaFiles() { try FileManager.default.removeItem(at: file) }
        try await waitUntil { s.post(id: id)?.status != .processing }

        XCTAssertEqual(s.post(id: id)?.status, .needsEvidence)
        XCTAssertEqual(s.post(id: id)?.failureMessage, PlanditStore.shareVideoAgainMessage)
    }

    /// Choosing a video in the app that isn't there: the same, and our own reasons stay as they are.
    @MainActor func testProcessVideoKeepsOurReasonsAndHidesSystemErrors() async throws {
        let post = SavedPost(url: URL(string: "plandit-video://test")!, platform: .video, savedAt: .now,
                             status: .needsEvidence, failureMessage: PlanditStore.shareVideoAgainMessage)
        let s = PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: [post], profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil),
            videoExtractor: VideoEvidenceExtractor(mediaStore: mediaStore), mediaStore: mediaStore
        )
        let missing = directory.appending(path: "missing.mov")
        _ = try? await s.processVideo(postID: post.id, fileURL: missing)
        XCTAssertEqual(s.post(id: post.id)?.failureMessage, PlanditStore.shareVideoAgainMessage)

        let text = directory.appending(path: "notes.txt")
        try Data("hi".utf8).write(to: text)
        _ = try? await s.processVideo(postID: post.id, fileURL: text)
        XCTAssertEqual(s.post(id: post.id)?.failureMessage, VideoEvidenceError.unsupportedType.errorDescription)
    }

    // MARK: - Sync during an in-app read (nice-to-have 7)

    /// A video chosen in the app is being read when a sync arrives: it keeps looking.
    @MainActor func testSyncDuringAnInAppVideoReadLeavesThePostLooking() async throws {
        let reader = GatedVideoReader()
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: reader)
        let file = directory.appending(path: "picked.mov")
        try Data(count: 512).write(to: file)
        let task = Task { try await s.saveVideo(fileURL: file) }
        try await waitUntil { reader.continuation != nil }
        let id = try XCTUnwrap(s.saved.first?.id)

        s.replace(with: StoreSnapshot(saved: s.saved, today: s.today, profile: s.profile, pastPlans: [], visited: []))

        XCTAssertEqual(s.post(id: id)?.status, .processing)
        XCTAssertNotEqual(s.post(id: id)?.failureMessage, PlanditStore.shareVideoAgainMessage)
        reader.continuation?.resume()
        _ = try? await task.value
    }

    /// The same for "Choose the video again" on a post that asked for it.
    @MainActor func testSyncDuringAVideoChosenAgainLeavesThePostLooking() async throws {
        let reader = GatedVideoReader()
        let post = SavedPost(url: URL(string: "plandit-video://again")!, platform: .video, savedAt: .now,
                             status: .needsEvidence, failureMessage: PlanditStore.shareVideoAgainMessage)
        let s = PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: [post], profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil),
            videoExtractor: reader, mediaStore: mediaStore
        )
        let file = directory.appending(path: "picked.mov")
        try Data(count: 512).write(to: file)
        let task = Task { try await s.processVideo(postID: post.id, fileURL: file) }
        try await waitUntil { reader.continuation != nil }

        s.replace(with: StoreSnapshot(saved: s.saved, today: s.today, profile: s.profile, pastPlans: [], visited: []))

        XCTAssertEqual(s.post(id: post.id)?.status, .processing)
        reader.continuation?.resume()
        _ = try? await task.value
    }

    /// Another phone's copy arrives with a video post it's still reading: this phone leaves it
    /// looking. Only a launch turns it into "Share the video again".
    @MainActor func testAVideoAnotherPhoneIsReadingStaysLookingAfterSync() {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        let elsewhere = SavedPost(url: URL(string: "plandit-video://elsewhere")!, platform: .video, savedAt: .now, status: .processing)

        s.replace(with: StoreSnapshot(saved: [elsewhere], today: s.today, profile: s.profile, pastPlans: [], visited: []))

        XCTAssertEqual(s.post(id: elsewhere.id)?.status, .processing)
        XCTAssertNil(s.post(id: elsewhere.id)?.failureMessage)
    }

    // MARK: - Re-import after a crash (nice-to-have 8)

    /// The app saved the post, then quit before acknowledging the share: the share comes back
    /// next launch and must not become a second post.
    @MainActor func testAShareImportedTwiceIsOnePost() throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        let share = try stageSharedVideo()
        XCTAssertEqual(s.ingestPendingShares().count, 1)
        ShareInbox.enqueue(share)

        XCTAssertEqual(s.ingestPendingShares(), [share.id], "the share opens the post it already made")

        XCTAssertEqual(s.saved.count, 1)
        XCTAssertEqual(s.saved.first?.id, share.id)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    /// The same for a link: still one post.
    @MainActor func testALinkShareImportedTwiceIsOnePost() throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        let share = IncomingShare(url: URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!)
        ShareInbox.enqueue(share)
        _ = s.ingestPendingShares()
        ShareInbox.enqueue(share)
        _ = s.ingestPendingShares()
        XCTAssertEqual(s.saved.count, 1)
    }

    // MARK: - The queue is shared by two processes (nice-to-have 9)

    /// The extension queues while the app acknowledges: no share is lost to the other's write.
    /// (Threads stand in for the two processes; the lock is a file lock, which covers both.)
    func testSharesQueuedAtOnceAreAllKept() {
        let count = 60
        DispatchQueue.concurrentPerform(iterations: count) { n in
            ShareInbox.enqueue(IncomingShare(url: URL(string: "https://www.tiktok.com/@a/video/\(7_400_000_000_000_000_000 + n)")!))
        }
        XCTAssertEqual(ShareInbox.pending().count, count)
    }

    /// Acknowledging one share while others are queued keeps the others.
    func testAcknowledgingWhileQueuingKeepsTheRest() {
        let first = (0..<30).map { IncomingShare(url: URL(string: "https://www.tiktok.com/@a/video/\(7_400_000_000_000_000_100 + $0)")!) }
        for share in first { ShareInbox.enqueue(share) }
        DispatchQueue.concurrentPerform(iterations: 60) { n in
            if n < 30 {
                ShareInbox.acknowledge(first[n].id)
            } else {
                ShareInbox.enqueue(IncomingShare(url: URL(string: "https://www.tiktok.com/@a/video/\(7_400_000_000_000_000_200 + n)")!))
            }
        }
        XCTAssertEqual(ShareInbox.pending().count, 30)
        XCTAssertTrue(ShareInbox.pending().allSatisfy { share in !first.contains { $0.id == share.id } })
    }

    // MARK: - Closing the sheet while it saves (nice-to-have 10)

    /// The sheet is dismissed while a video from Files is being copied: nothing is queued and no
    /// copy is left behind.
    @MainActor func testClosingWhileAFileIsSavingQueuesNothing() async throws {
        let file = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: file)
        let flow = ShareFlow(intake: ShareIntake(mediaStore: mediaStore))

        let task = Task { await flow.start(providers: [NSItemProvider(object: file as NSURL)]) }
        task.cancel()
        await task.value

        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertTrue(mediaFiles().isEmpty)
    }

    /// The same for a video from Photos (handed over as a movie file).
    @MainActor func testClosingWhileAMovieIsSavingQueuesNothing() async throws {
        let file = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: file)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let flow = ShareFlow(intake: ShareIntake(mediaStore: mediaStore))

        let task = Task { await flow.start(providers: [provider]) }
        task.cancel()
        await task.value

        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertTrue(mediaFiles().isEmpty)
    }

    // MARK: - The 250 MB cap when the size is unknown (nice-to-have 11)

    /// The source won't say how big it is: the copy is checked instead, and an oversized one is
    /// deleted and reported as too large.
    @MainActor func testAVideoOfUnknownSizeOverTheCapIsTooLarge() throws {
        let source = directory.appending(path: "huge.mov")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(TemporaryMediaStore.maximumBytes + 1))
        try handle.close()
        let unknownSize = TemporaryMediaStore(root: mediaStore.root, sourceSize: { _ in nil })

        XCTAssertEqual(ShareIntake.stage(source, in: unknownSize), .problem(.videoTooLarge))
        XCTAssertTrue(mediaFiles().isEmpty, "the copy is deleted")
    }

    /// Under the cap, the same video is kept.
    @MainActor func testAVideoOfUnknownSizeUnderTheCapIsKept() throws {
        let source = directory.appending(path: "small.mov")
        try Data(count: 512).write(to: source)
        let unknownSize = TemporaryMediaStore(root: mediaStore.root, sourceSize: { _ in nil })

        guard case .video = ShareIntake.stage(source, in: unknownSize) else { return XCTFail("should be staged") }
        XCTAssertEqual(mediaFiles().count, 1)
    }

    @MainActor func testByteCountReadsAFilesSize() throws {
        let source = directory.appending(path: "small.mov")
        try Data(count: 512).write(to: source)
        XCTAssertEqual(TemporaryMediaStore.byteCount(of: source), 512)
        XCTAssertNil(TemporaryMediaStore.byteCount(of: directory.appending(path: "missing.mov")))
    }

    // MARK: - When a shared link was saved (nice-to-have 13)

    /// A link shared yesterday and opened today is dated when it was shared, like a video.
    @MainActor func testASharedLinkIsDatedWhenItWasShared() throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        let sharedAt = Date(timeIntervalSinceNow: -86_400)
        ShareInbox.enqueue(IncomingShare(url: URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!, receivedAt: sharedAt))

        let id = try XCTUnwrap(s.ingestPendingShares().first)

        XCTAssertEqual(try XCTUnwrap(s.post(id: id)?.savedAt).timeIntervalSince1970, sharedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A link added in the app is dated now.
    @MainActor func testALinkAddedInTheAppIsDatedNow() throws {
        let s = store(extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil), video: GatedVideoReader())
        let id = try s.save(url: URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000002")!)
        XCTAssertLessThan(abs(try XCTUnwrap(s.post(id: id)?.savedAt).timeIntervalSinceNow), 5)
    }

    /// At the app's launch, a read left behind goes at once, however fresh; videos still waiting to
    /// be read stay.
    @MainActor func testLaunchDeletesAbandonedReadsButNotWaitingVideos() throws {
        let source = directory.appending(path: "clip.mov")
        try Data(count: 512).write(to: source)
        let abandoned = try mediaStore.claimForReading(try mediaStore.stage(source))
        let waiting = try mediaStore.stage(source)

        mediaStore.removeAbandonedReads()

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.path))
    }

    /// A share can't name the `Reading/` folder itself.
    @MainActor func testAShareCantNameTheReadingFolder() {
        XCTAssertNil(mediaStore.file(named: "Reading"))
    }
}
