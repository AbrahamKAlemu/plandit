import UniformTypeIdentifiers
import XCTest
@testable import Plandit

/// The share extension's logic (SHR-1 to SHR-6), driven with `NSItemProvider`s the way a share
/// sheet hands them over. The extension's own UI can't be driven from the app's UI tests.
final class ShareIntakeTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ShareIntakeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    @MainActor private func stagedFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: mediaStore.root.path)) ?? []
    }

    /// A file with a movie's extension. Its bytes don't matter: the share sheet never reads them.
    private func movie(named name: String = "clip.mov", bytes: Int64 = 1024) throws -> URL {
        let url = directory.appending(path: name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return url
    }

    @MainActor private func share(_ providers: [NSItemProvider], store: TemporaryMediaStore? = nil) async -> ShareFlow {
        let flow = ShareFlow(intake: ShareIntake(mediaStore: store ?? mediaStore))
        await flow.start(providers: providers)
        return flow
    }

    // MARK: - 1.0 compatibility

    @MainActor func testQueuedEntryFrom1Point0StillDecodes() throws {
        let json = """
        [{"id":"8F6B2C2E-6A55-4B53-9C1D-7E1C4F0B2A11","url":"https:\\/\\/www.tiktok.com\\/@nycbites\\/video\\/7400000000000000001","sharedText":"Levain cookies","receivedAt":785000000}]
        """
        let shares = try JSONDecoder().decode([IncomingShare].self, from: Data(json.utf8))
        XCTAssertEqual(shares.count, 1)
        XCTAssertEqual(shares[0].url?.absoluteString, "https://www.tiktok.com/@nycbites/video/7400000000000000001")
        XCTAssertEqual(shares[0].sharedText, "Levain cookies")
        XCTAssertNil(shares[0].videoFileName)
        XCTAssertEqual(shares[0].receivedAt, Date(timeIntervalSinceReferenceDate: 785_000_000))
    }

    @MainActor func testQueuedEntryFrom1Point0IsImportedByTheApp() throws {
        let json = """
        [{"id":"8F6B2C2E-6A55-4B53-9C1D-7E1C4F0B2A12","url":"https:\\/\\/www.tiktok.com\\/@nycbites\\/video\\/7400000000000000002","receivedAt":785000000}]
        """
        AppGroup.defaults.set(Data(json.utf8), forKey: "plandit.pendingShares")
        let store = PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: [], profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        )
        XCTAssertEqual(store.ingestPendingShares().count, 1)
        XCTAssertEqual(store.saved.first?.platform, .tiktok)
        // The creator shows while the place is found (PRC-2).
        XCTAssertEqual(store.saved.first?.creatorHandle, "@nycbites")
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    // MARK: - SHR-1 links save without a tap

    @MainActor func testTikTokLinkIsSavedStraightAway() async {
        let url = URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001?is_from_webapp=1")!
        let flow = await share([NSItemProvider(object: url as NSURL)])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .tiktok, creator: "@nycbites")))
        let pending = ShareInbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.url?.absoluteString, "https://www.tiktok.com/@nycbites/video/7400000000000000001")
        XCTAssertNil(pending.first?.videoFileName)
    }

    @MainActor func testLinkInSharedTextKeepsTheCaptionWithoutTheLink() async {
        let text = "The cookies at Levain are worth the line https://www.instagram.com/reel/DHZYjjnPKez/?igsh=abc"
        let flow = await share([NSItemProvider(object: text as NSString)])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .instagram, caption: "The cookies at Levain are worth the line")))
        XCTAssertEqual(ShareInbox.pending().first?.url?.absoluteString, "https://www.instagram.com/reel/DHZYjjnPKez")
        XCTAssertEqual(ShareInbox.pending().first?.sharedText, text)
    }

    @MainActor func testURLAttachmentKeepsTextSharedAlongsideIt() async {
        let url = URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000003")!
        let flow = await share([
            NSItemProvider(object: "Best tacos in Chelsea Market" as NSString),
            NSItemProvider(object: url as NSURL),
        ])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .tiktok, creator: "@nycbites", caption: "Best tacos in Chelsea Market")))
        XCTAssertEqual(ShareInbox.pending().first?.sharedText, "Best tacos in Chelsea Market")
    }

    @MainActor func testFirstSupportedLinkInTextWins() async {
        let text = "via https://example.com/blog then https://vm.tiktok.com/ZMabc123/"
        let flow = await share([NSItemProvider(object: text as NSString)])

        guard case .saved(let summary) = flow.state else { return XCTFail("Expected saved, got \(flow.state)") }
        XCTAssertEqual(summary.platform, .tiktok)
        XCTAssertEqual(ShareInbox.pending().first?.url?.host(), "vm.tiktok.com")
    }

    // MARK: - SHR-3 videos

    @MainActor func testVideoIsCopiedIntoPlanditsFolderAndQueuedByName() async throws {
        let source = try movie()
        let flow = await share([try XCTUnwrap(NSItemProvider(contentsOf: source))])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .video)))
        let pending = ShareInbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.url)
        let name = try XCTUnwrap(pending.first?.videoFileName)
        XCTAssertEqual(stagedFiles(), [name])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The original stays where it was")
    }

    @MainActor func testStagedCopyCountsItsDayFromTheShareNotTheFilming() throws {
        let source = try movie()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: source.path)

        let staged = try mediaStore.stage(source)
        mediaStore.removeExpiredFiles(now: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "A fresh share isn't deleted because the video is old")

        mediaStore.removeExpiredFiles(now: Date(timeIntervalSinceNow: 25 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Unread after 24 hours: deleted")
    }

    @MainActor func testFileSharedAsAURLIsCopiedToo() async throws {
        let source = try movie(named: "from-files.mp4")
        let flow = await share([NSItemProvider(object: source as NSURL)])

        XCTAssertEqual(flow.state, .saved(ShareSummary(platform: .video)))
        XCTAssertEqual(stagedFiles().count, 1)
    }

    // MARK: - SHR-4 problems save nothing

    @MainActor func testUnsupportedLinkSavesNothing() async {
        let flow = await share([NSItemProvider(object: URL(string: "https://example.com/article")! as NSURL)])

        XCTAssertEqual(flow.state, .problem(.unsupportedLink))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testTikTokProfileIsNotSupported() async {
        let flow = await share([NSItemProvider(object: URL(string: "https://www.tiktok.com/@nycbites")! as NSURL)])

        XCTAssertEqual(flow.state, .problem(.unsupportedLink))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testTextWithoutALinkSavesNothing() async {
        let flow = await share([NSItemProvider(object: "Meet at 3?" as NSString)])

        XCTAssertEqual(flow.state, .problem(.noLink))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testVideoOver250MBIsRefused() async throws {
        let source = try movie(bytes: TemporaryMediaStore.maximumBytes + 1)
        let flow = await share([try XCTUnwrap(NSItemProvider(contentsOf: source))])

        XCTAssertEqual(flow.state, .problem(.videoTooLarge))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    @MainActor func testFileThatIsntAVideoIsRefused() async throws {
        let source = directory.appending(path: "notes.txt")
        try Data("not a video".utf8).write(to: source)
        let flow = await share([NSItemProvider(object: source as NSURL)])

        XCTAssertEqual(flow.state, .problem(.notVideo))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    @MainActor func testBuildWithoutAppGroupRefusesVideosButStillSavesLinks() async throws {
        let video = ShareFlow(intake: ShareIntake(mediaStore: nil))
        await video.start(providers: [try XCTUnwrap(NSItemProvider(contentsOf: try movie()))])
        XCTAssertEqual(video.state, .problem(.videosUnavailable))
        XCTAssertTrue(ShareInbox.pending().isEmpty)

        let link = ShareFlow(intake: ShareIntake(mediaStore: nil))
        await link.start(providers: [NSItemProvider(object: URL(string: "https://www.tiktok.com/t/ZTabc/")! as NSURL)])
        guard case .saved = link.state else { return XCTFail("Expected saved, got \(link.state)") }
    }

    @MainActor func testEveryProblemNamesWhatWorks() {
        let problems: [ShareProblem] = [.unsupportedLink, .noLink, .notVideo, .videoNotSaved]
        for problem in problems {
            XCTAssertTrue(problem.message.contains("a TikTok, an Instagram post or Reel, or a video"), "\(problem)")
            XCTAssertFalse(problem.title.isEmpty)
        }
        XCTAssertTrue(ShareProblem.videoTooLarge.message.contains("250 MB"))
        XCTAssertTrue(ShareProblem.videoTooLarge.message.contains("a TikTok or an Instagram post or Reel"))
        XCTAssertTrue(ShareProblem.videosUnavailable.message.contains("a TikTok or an Instagram post or Reel"))
    }

    // MARK: - SHR-2 Undo

    @MainActor func testUndoTakesBackTheLink() async {
        let flow = await share([NSItemProvider(object: URL(string: "https://www.instagram.com/p/C1abc/")! as NSURL)])
        XCTAssertEqual(ShareInbox.pending().count, 1)

        flow.undo()
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    @MainActor func testUndoDeletesTheCopiedVideo() async throws {
        let flow = await share([try XCTUnwrap(NSItemProvider(contentsOf: try movie()))])
        XCTAssertEqual(stagedFiles().count, 1)

        flow.undo()
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    @MainActor func testUndoAfterTheAppTookTheShareChangesNothing() async {
        let flow = await share([NSItemProvider(object: URL(string: "https://www.tiktok.com/@a/video/1")! as NSURL)])
        let queued = ShareInbox.pending()
        guard let taken = queued.first else { return XCTFail("The share should be queued") }
        for share in queued { ShareInbox.acknowledge(share.id) }

        flow.undo()
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertFalse(ShareInbox.remove(taken.id, mediaStore: mediaStore))
    }

    // MARK: - SHR-6 the same link twice

    @MainActor func testSameLinkTwiceQueuesOnceAndStillSaysSaved() async {
        let url = URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!
        let first = await share([NSItemProvider(object: url as NSURL)])
        let second = await share([NSItemProvider(object: "Levain \(url.absoluteString)?lang=en" as NSString)])

        guard case .saved = first.state, case .saved = second.state else { return XCTFail("Both should say saved") }
        XCTAssertEqual(ShareInbox.pending().count, 1)

        // Undo on the repeat leaves the first share alone.
        second.undo()
        XCTAssertEqual(ShareInbox.pending().count, 1)
    }

    @MainActor func testSameLinkSharedTwiceBecomesOnePost() async {
        let url = URL(string: "https://www.tiktok.com/@nycbites/video/7400000000000000001")!
        _ = await share([NSItemProvider(object: url as NSURL)])
        let store = PlanditStore(
            today: DayPlan(date: .now, title: "Test", budget: 60, stops: [], legs: []),
            saved: [], profile: SampleData.profile, pastPlans: [], visited: [],
            extractor: FixturePlaceExtractor(metadataProvider: nil, placeSearcher: nil)
        )
        XCTAssertEqual(store.ingestPendingShares().count, 1)
        // Shared again after the app already has it.
        _ = await share([NSItemProvider(object: url as NSURL)])
        XCTAssertEqual(store.ingestPendingShares().count, 1)
        XCTAssertEqual(store.saved.count, 1)
    }

    // MARK: - SHR-5 closing

    @MainActor func testConfirmationClosesAfterTwoSecondsUnlessVoiceOverIsOn() {
        XCTAssertEqual(ShareClosePolicy.autoCloseDelay(isVoiceOverRunning: false), .seconds(2))
        XCTAssertNil(ShareClosePolicy.autoCloseDelay(isVoiceOverRunning: true))
    }

    // MARK: - Captions

    @MainActor func testCaptionsLoseTheirLinks() {
        XCTAssertNil(LinkParser.textWithoutLinks("https://www.tiktok.com/@sample.creator/video/1"))
        XCTAssertNil(LinkParser.textWithoutLinks("  "))
        XCTAssertEqual(LinkParser.textWithoutLinks("Try Levain Bakery https://www.tiktok.com/@c/video/1 now"), "Try Levain Bakery now")
        XCTAssertEqual(LinkParser.textWithoutLinks("tiktok.com/@c/video/1\nSunset on the High Line"), "Sunset on the High Line")
    }

    @MainActor func testSummaryShowsPlatformAndCreator() {
        XCTAssertEqual(ShareSummary(platform: .tiktok, creator: "@nycbites").sourceLine, "TikTok · @nycbites")
        XCTAssertEqual(ShareSummary(platform: .instagram).sourceLine, "Instagram")
        XCTAssertEqual(ShareSummary(platform: .video).sourceLine, "Video")
    }
}
