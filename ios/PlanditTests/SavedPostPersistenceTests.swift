import XCTest
@testable import Plandit

@MainActor
final class SavedPostPersistenceTests: XCTestCase {
    func testPostSurvivesRepositoryReload() throws {
        let persistence = try SavedPostPersistence(inMemory: true)
        let post = SavedPost(
            url: URL(string: "https://www.tiktok.com/@creator/video/123")!,
            canonicalURL: URL(string: "https://www.tiktok.com/@creator/video/123")!,
            platform: .tiktok,
            caption: "Levain Bakery",
            savedAt: .now,
            status: .needsConfirmation,
            candidates: [
                PlaceCandidate(
                    id: "fixture:levain",
                    place: SampleData.levain,
                    confidence: .high,
                    reason: "Name matched the shared text",
                    estimatedCost: 6
                )
            ]
        )

        try persistence.upsert(post)

        XCTAssertEqual(try persistence.load().first, post)
    }

    func testCanonicalURLUpsertsInsteadOfDuplicating() throws {
        let persistence = try SavedPostPersistence(inMemory: true)
        var post = SavedPost(
            url: URL(string: "https://instagram.com/reel/ABC")!,
            canonicalURL: URL(string: "https://instagram.com/reel/ABC")!,
            platform: .instagram,
            savedAt: .now,
            status: .needsEvidence
        )
        try persistence.upsert(post)
        post.caption = "Updated evidence"
        try persistence.upsert(post)

        let posts = try persistence.load()

        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].caption, "Updated evidence")
    }
}
