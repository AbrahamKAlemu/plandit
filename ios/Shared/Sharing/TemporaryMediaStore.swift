import Foundation
import os
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
/// A file being read sits in `Reading/`, out of the cleanup's way.
nonisolated struct TemporaryMediaStore {
    static let maximumBytes: Int64 = 250 * 1024 * 1024
    /// How long an unread video may wait before it's deleted.
    static let lifetime: TimeInterval = 24 * 60 * 60
    let root: URL
    /// How big a video to be copied in is, or nil when that can't be told. Replaceable for tests.
    private let sourceSize: @Sendable (URL) -> Int64?

    init(root: URL? = nil, sourceSize: @escaping @Sendable (URL) -> Int64? = TemporaryMediaStore.byteCount(of:)) {
        let base = AppGroup.containerURL ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appending(path: "TemporaryMedia", directoryHint: .isDirectory)
        self.sourceSize = sourceSize
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
            // The source didn't say how big it was: the copy does.
            if let copied = Self.byteCount(of: destination), copied > Self.maximumBytes {
                throw VideoEvidenceError.tooLarge
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    func validate(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = values.contentType, contentType.conforms(to: .movie) else {
            throw VideoEvidenceError.unsupportedType
        }
        if let size = sourceSize(source), size > Self.maximumBytes {
            throw VideoEvidenceError.tooLarge
        }
    }

    /// A file's size: its length, else the space it takes, else what the file system reports.
    static func byteCount(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        if let size = values?.fileSize ?? values?.totalFileAllocatedSize { return Int64(size) }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Where a video waits while it's read: the 24-hour cleanup (here, or in the share extension's
    /// process) skips this folder, so it can't delete a video mid-read.
    var readingFolder: URL { root.appending(path: Self.readingFolderName, directoryHint: .isDirectory) }
    private static let readingFolderName = "Reading"
    /// A read never takes this long: a file still in `Reading/` after 48 hours was left by a read
    /// the app never finished (it quit, or was stopped), and is deleted.
    static let abandonedReadLifetime: TimeInterval = 48 * 60 * 60

    /// Whether a file sits directly in this folder or in `Reading/` (so it's one of ours to read or delete).
    func contains(_ url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        return folder == root.standardizedFileURL || folder == readingFolder.standardizedFileURL
    }

    /// The staged file a share names, or nil when the name could point outside this folder.
    func file(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name != Self.readingFolderName else { return nil }
        let url = root.appending(path: name)
        return contains(url) ? url : nil
    }

    /// Moves a staged video into `Reading/` before it's read, and restarts its clock. Throws when
    /// the file is gone (cleaned up, say). A file already there is returned as it is.
    func claimForReading(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        if folder == readingFolder.standardizedFileURL { return url }
        guard folder == root.standardizedFileURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.createDirectory(at: readingFolder, withIntermediateDirectories: true)
        let destination = readingFolder.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        return destination
    }

    func remove(_ url: URL) throws {
        guard contains(url) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every file staged more than 24 hours ago and not being read (a partial copy from an
    /// extension that was stopped included), and any read abandoned for 48 hours. A share whose
    /// video is gone asks for the video again in the app.
    /// A file it can't delete is logged and skipped, so one stuck file never keeps the rest; a file
    /// that's already gone (read and deleted meanwhile) is fine.
    func removeExpiredFiles(now: Date = Date()) {
        removeExpiredFiles(in: root, olderThan: now.addingTimeInterval(-Self.lifetime))
        removeExpiredFiles(in: readingFolder, olderThan: now.addingTimeInterval(-Self.abandonedReadLifetime))
    }

    /// Deletes every video left in `Reading/`. A read never outlives its process, so at the app's
    /// launch anything there was abandoned. App only: the share extension must never call this,
    /// since the app may be reading while the extension runs. The 48-hour sweep stays as a backstop.
    func removeAbandonedReads() {
        removeExpiredFiles(in: readingFolder, olderThan: .distantFuture)
    }

    private func removeExpiredFiles(in folder: URL, olderThan cutoff: Date) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            if !Self.isMissingFile(error) {
                Self.log.error("Couldn't list temporary media: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        for file in files {
            do {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                if values.isDirectory != true, (values.contentModificationDate ?? .distantPast) < cutoff {
                    try remove(file)
                }
            } catch where Self.isMissingFile(error) {
                continue
            } catch {
                Self.log.error(
                    "Couldn't delete expired \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static let log = Logger(subsystem: "com.plandit.app", category: "TemporaryMedia")

    /// Whether an error only says the file (or folder) isn't there.
    static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSCocoaErrorDomain: return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        case NSPOSIXErrorDomain: return error.code == Int(ENOENT)
        default: return false
        }
    }
}
