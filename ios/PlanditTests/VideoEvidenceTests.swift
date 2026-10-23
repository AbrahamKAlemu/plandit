import XCTest
@testable import Plandit

final class VideoEvidenceTests: XCTestCase {
    @MainActor func testCombinesAndDeduplicatesEvidence() {
        let evidence = VideoEvidence.combine(
            frameText: ["Levain Bakery", "LEVain bakery", "Upper West Side"],
            transcript: "Try Levain Bakery on the Upper West Side"
        )

        XCTAssertTrue(evidence.contains("Levain Bakery"))
        XCTAssertTrue(evidence.contains("Upper West Side"))
        XCTAssertEqual(evidence.components(separatedBy: "\n").filter { $0 == "Levain Bakery" }.count, 1)
    }

    @MainActor func testTemporaryMediaIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TemporaryMediaStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TemporaryMediaStore(root: root.appending(path: "staged", directoryHint: .isDirectory))
        let staged = try store.stage(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        try store.remove(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    @MainActor func testOversizedVideoIsRejectedBeforeStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OversizedVideoTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "large.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(250 * 1024 * 1024 + 1))
        try handle.close()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = TemporaryMediaStore(root: root.appending(path: "staged", directoryHint: .isDirectory))

        XCTAssertThrowsError(try store.validate(source)) { error in
            XCTAssertEqual(error as? VideoEvidenceError, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    @MainActor func testSilentVideoSkipsSpeechRecognition() {
        XCTAssertFalse(VideoEvidenceExtractor.shouldAttemptTranscription(audioTrackCount: 0))
        XCTAssertTrue(VideoEvidenceExtractor.shouldAttemptTranscription(audioTrackCount: 1))
    }
}
