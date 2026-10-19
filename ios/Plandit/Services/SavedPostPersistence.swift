import Foundation
import SwiftData

@Model
final class SavedPostRecord {
    @Attribute(.unique) var canonicalURL: String
    var payload: Data

    init(canonicalURL: String, payload: Data) {
        self.canonicalURL = canonicalURL
        self.payload = payload
    }
}

@MainActor
final class SavedPostPersistence {
    private let container: ModelContainer
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: SavedPostRecord.self, configurations: configuration)
        context = container.mainContext
    }

    func load() throws -> [SavedPost] {
        let records = try context.fetch(FetchDescriptor<SavedPostRecord>())
        return try records
            .map { try decoder.decode(SavedPost.self, from: $0.payload) }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func upsert(_ post: SavedPost) throws {
        let key = post.canonicalURL.absoluteString
        let descriptor = FetchDescriptor<SavedPostRecord>(
            predicate: #Predicate { $0.canonicalURL == key }
        )
        let data = try encoder.encode(post)
        if let record = try context.fetch(descriptor).first {
            record.payload = data
        } else {
            context.insert(SavedPostRecord(canonicalURL: key, payload: data))
        }
        try context.save()
    }

    func delete(canonicalURL: URL) throws {
        let key = canonicalURL.absoluteString
        let descriptor = FetchDescriptor<SavedPostRecord>(
            predicate: #Predicate { $0.canonicalURL == key }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }
}
