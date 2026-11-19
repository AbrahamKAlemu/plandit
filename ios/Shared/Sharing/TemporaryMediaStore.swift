import Foundation
import UniformTypeIdentifiers

nonisolated enum VideoEvidenceError: LocalizedError, Equatable {
    case unsupportedType
    case tooLarge
    case tooLong
    case noEvidence

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "Choose a standard video file such as MP4, MOV, or M4V."
        case .tooLarge:
            "Choose a video smaller than 250 MB."
        case .tooLong:
            "Choose a video shorter than five minutes."
        case .noEvidence:
            "We couldn't read a place name from that video. Add the name or neighborhood yourself."
        }
    }
}

/// Plandit's own folder for videos waiting to be read: `TemporaryMedia/` in the App Group container,
/// so the share extension can stage a video the app reads later. Nothing in it is ever uploaded.
/// A file is deleted once it's read, or by `removeExpiredFiles` 24 hours after it was staged.
nonisolated struct TemporaryMediaStore {
    static let maximumBytes: Int64 = 250 * 1024 * 1024
    /// How long an unread video may wait before it's deleted.
    static let lifetime: TimeInterval = 24 * 60 * 60
    let root: URL

    init(root: URL? = nil) {
        let base = AppGroup.containerURL ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appending(path: "TemporaryMedia", directoryHint: .isDirectory)
    }

    /// The App Group's folder, or nil when the build has no App Group container (an unsigned
    /// simulator build): the share extension then can't hand a video to the app.
    static var shared: TemporaryMediaStore? {
        AppGroup.containerURL.map {
            TemporaryMediaStore(root: $0.appending(path: "TemporaryMedia", directoryHint: .isDirectory))
        }
    }

    /// Copies a video in, after checking it's a movie of at most 250 MB. The copy's modification
    /// date is now, so the 24 hours count from the share, not from when the video was filmed.
    func stage(_ source: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        try validate(source)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let extensionName = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = root.appending(path: "\(UUID().uuidString).\(extensionName)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    func validate(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let contentType = values.contentType, contentType.conforms(to: .movie) else {
            throw VideoEvidenceError.unsupportedType
        }
        if let fileSize = values.fileSize, Int64(fileSize) > Self.maximumBytes {
            throw VideoEvidenceError.tooLarge
        }
    }

    /// Whether a file sits directly in this folder (so it's one of ours to read or delete).
    func contains(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    }

    /// The staged file a share names, or nil when the name could point outside this folder.
    func file(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = root.appending(path: name)
        return contains(url) ? url : nil
    }

    func remove(_ url: URL) throws {
        guard contains(url) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every file staged before `cutoff`, read or not (a partial copy from an extension
    /// that was stopped included). A share whose video is gone asks for the video again in the app.
    func removeExpiredFiles(olderThan cutoff: Date) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for file in files {
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if modified < cutoff {
                try remove(file)
            }
        }
    }

    /// `removeExpiredFiles` with the 24-hour rule.
    func removeExpiredFiles(now: Date = Date()) throws {
        try removeExpiredFiles(olderThan: now.addingTimeInterval(-Self.lifetime))
    }
}
