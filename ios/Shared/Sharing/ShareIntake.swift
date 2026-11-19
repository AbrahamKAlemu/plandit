import Foundation
import Observation
import UniformTypeIdentifiers

/// What the share sheet was handed, once read.
nonisolated enum ShareIntakeResult: Equatable, Sendable {
    /// A supported TikTok or Instagram link (canonical), with any text that came with it.
    case link(URL, sharedText: String?)
    /// A video copied into `TemporaryMedia/` under this file name.
    case video(stagedFileName: String)
    case problem(ShareProblem)
}

/// Why the share sheet can't save something. Each message names what works (SHR-4).
nonisolated enum ShareProblem: Equatable, Sendable {
    case unsupportedLink
    case noLink
    case notVideo
    case videoTooLarge
    /// No App Group folder (an unsigned build): a video copied here would never reach the app.
    case videosUnavailable
    case videoNotSaved

    static let whatWorks = "Share a TikTok, an Instagram post or Reel, or a video."

    var title: String {
        switch self {
        case .unsupportedLink: "Plandit can't save this link"
        case .noLink: "There's nothing to save here"
        case .notVideo: "This file isn't a video"
        case .videoTooLarge: "This video is too large"
        case .videosUnavailable: "Plandit can't save videos here"
        case .videoNotSaved: "Plandit couldn't save this video"
        }
    }

    var message: String {
        switch self {
        case .unsupportedLink: "Plandit can save a TikTok, an Instagram post or Reel, or a video."
        case .noLink: "This share didn't include a link or a video. \(Self.whatWorks)"
        case .notVideo: Self.whatWorks
        case .videoTooLarge: "Try a shorter video, up to 250 MB. You can also share a TikTok or an Instagram post or Reel."
        case .videosUnavailable: "Share a TikTok or an Instagram post or Reel instead."
        case .videoNotSaved: "Try sharing it again. \(Self.whatWorks)"
        }
    }
}

/// Reads a share sheet's attachments: a movie file first, then a URL, then the first supported link
/// in shared text. A video is copied into Plandit's own folder before anything is queued.
struct ShareIntake {
    /// Nil when the build has no App Group container.
    let mediaStore: TemporaryMediaStore?

    init(mediaStore: TemporaryMediaStore? = TemporaryMediaStore.shared) {
        self.mediaStore = mediaStore
    }

    func read(_ providers: [NSItemProvider], contentText: [String] = []) async -> ShareIntakeResult {
        // 1. A movie (Photos, Files, or an app sharing its video).
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) {
            return await stageMovie(from: provider)
        }

        var texts = contentText
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let text = await provider.loadText() { texts.append(text) }
        }
        let sharedText = Self.joined(texts)

        // 2. A URL attachment: a web link, or a file someone shared from Files.
        var sawLink = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await provider.loadURL() else { continue }
            if url.isFileURL {
                return await stage(fileURL: url)
            }
            sawLink = true
            if let supported = try? SupportedSocialURL(url) {
                return .link(supported.canonicalURL, sharedText: sharedText)
            }
        }

        // 3. The first supported link inside the text (TikTok often shares "caption https://…").
        for text in texts {
            for url in LinkParser.webURLs(in: text) {
                sawLink = true
                if let supported = try? SupportedSocialURL(url) {
                    return .link(supported.canonicalURL, sharedText: sharedText)
                }
            }
        }
        return .problem(sawLink ? .unsupportedLink : .noLink)
    }

    private static func joined(_ texts: [String]) -> String? {
        var seen = Set<String>()
        let unique = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    private func stageMovie(from provider: NSItemProvider) async -> ShareIntakeResult {
        guard let mediaStore else { return .problem(.videosUnavailable) }
        return await provider.stageMovie(in: mediaStore)
    }

    private func stage(fileURL: URL) async -> ShareIntakeResult {
        guard let mediaStore else {
            let isMovie = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .movie)) ?? false
            return .problem(isMovie ? .videosUnavailable : .notVideo)
        }
        return await Self.stageInBackground(fileURL, in: mediaStore)
    }

    /// A video from Files can be hundreds of megabytes: it's copied off the main actor, so the
    /// sheet (and its Cancel button) keeps responding.
    @concurrent
    private nonisolated static func stageInBackground(_ source: URL, in mediaStore: TemporaryMediaStore) async -> ShareIntakeResult {
        stage(source, in: mediaStore)
    }

    /// Deletes the copy a result made, for a share that won't be queued after all.
    func discard(_ result: ShareIntakeResult) {
        guard case .video(let fileName) = result, let mediaStore, let file = mediaStore.file(named: fileName) else { return }
        try? mediaStore.remove(file)
    }

    nonisolated static func stage(_ source: URL, in mediaStore: TemporaryMediaStore) -> ShareIntakeResult {
        do {
            return .video(stagedFileName: try mediaStore.stage(source).lastPathComponent)
        } catch VideoEvidenceError.tooLarge {
            return .problem(.videoTooLarge)
        } catch VideoEvidenceError.unsupportedType {
            return .problem(.notVideo)
        } catch {
            return .problem(.videoNotSaved)
        }
    }
}

/// What the confirmation shows about a saved share: the platform, and the creator and caption
/// when the share included them.
struct ShareSummary: Equatable {
    var platform: SourcePlatform
    var creator: String?
    var caption: String?

    init(platform: SourcePlatform, creator: String? = nil, caption: String? = nil) {
        self.platform = platform
        self.creator = creator
        self.caption = caption
    }

    init(_ result: ShareIntakeResult) {
        switch result {
        case .link(let url, let sharedText):
            self.init(
                platform: SourcePlatform(url: url),
                creator: url.pathComponents.first { $0.hasPrefix("@") && $0.count > 1 },
                caption: LinkParser.textWithoutLinks(sharedText)
            )
        case .video, .problem:
            self.init(platform: .video)
        }
    }

    /// "TikTok · @creator", "Instagram", "Video".
    var sourceLine: String {
        [platform.displayName, creator].compactMap { $0 }.joined(separator: " · ")
    }
}

/// When the confirmation closes by itself: after about 2 s, but never while VoiceOver is on (SHR-5).
enum ShareClosePolicy {
    static let delay: Duration = .seconds(2)

    static func autoCloseDelay(isVoiceOverRunning: Bool) -> Duration? {
        isVoiceOverRunning ? nil : delay
    }
}

/// The share sheet's flow: read, save straight away, then "Saved to Plandit" with Undo, or a
/// problem with Close. The extension's view controller only wires this to the extension context.
@Observable
@MainActor
final class ShareFlow {
    enum State: Equatable {
        case saving
        case saved(ShareSummary)
        case problem(ShareProblem)
        /// Undo came too late: Plandit had already taken the share.
        case alreadyTaken
    }

    static let alreadyTakenMessage = "Plandit already has this one. You can remove it in Saved."

    private(set) var state: State = .saving
    /// The queued share this sheet added, which Undo takes back. Nil when the link was already
    /// waiting in the queue: Undo then leaves that earlier share alone.
    @ObservationIgnored private(set) var addedShareID: UUID?
    @ObservationIgnored private let intake: ShareIntake

    init(intake: ShareIntake = ShareIntake()) {
        self.intake = intake
    }

    func start(items: [NSExtensionItem]) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        let contentText = items.compactMap { $0.attributedContentText?.string }
        await start(providers: providers, contentText: contentText)
    }

    func start(providers: [NSItemProvider], contentText: [String] = []) async {
        state = .saving
        let result = await intake.read(providers, contentText: contentText)
        // The sheet closed while it was saving: queue nothing, and drop any copy already made.
        // (Nothing suspends between this check and the enqueue below.)
        if Task.isCancelled {
            intake.discard(result)
            return
        }
        let share: IncomingShare
        switch result {
        case .problem(let problem):
            state = .problem(problem)
            return
        case .link(let url, let sharedText):
            share = IncomingShare(url: url, sharedText: sharedText)
        case .video(let fileName):
            share = IncomingShare(videoFileName: fileName)
        }
        let stored = ShareInbox.enqueue(share)
        addedShareID = stored.isNew ? stored.share.id : nil
        state = .saved(ShareSummary(result))
    }

    /// Takes the share back, with any video it copied, before the app sees it. Returns false when
    /// Plandit took it first: the sheet then says so and stays open (`alreadyTaken`).
    @discardableResult
    func undo() -> Bool {
        defer { addedShareID = nil }
        guard let addedShareID, !ShareInbox.remove(addedShareID, mediaStore: intake.mediaStore) else { return true }
        state = .alreadyTaken
        return false
    }
}

/// An item provider's load, which a cancel may reach before or after it starts.
private nonisolated final class PendingLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var isCancelled = false
    private var isCompleted = false

    /// True the first time only: a cancelled load can call back twice.
    func complete() -> Bool {
        lock.withLock {
            defer { isCompleted = true }
            return !isCompleted
        }
    }

    func started(_ progress: Progress) {
        lock.withLock {
            self.progress = progress
            if isCancelled { progress.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            progress?.cancel()
        }
    }
}

/// Nonisolated: the provider calls back on its own queue.
private nonisolated extension NSItemProvider {
    /// The movie's file only exists inside the callback, so it's copied there. Cancelling (the
    /// sheet closed) stops the load.
    func stageMovie(in mediaStore: TemporaryMediaStore) async -> ShareIntakeResult {
        let load = PendingLoad()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let progress = loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard load.complete() else { return }
                    guard let url else {
                        continuation.resume(returning: .problem(.videoNotSaved))
                        return
                    }
                    continuation.resume(returning: ShareIntake.stage(url, in: mediaStore))
                }
                load.started(progress)
            }
        } onCancel: {
            load.cancel()
        }
    }

    /// Apps hand a link over as a URL object (the classic `loadItem` way) or as data that only
    /// decodes through `NSURL` (`NSItemProvider(object:)`); both work.
    func loadURL() async -> URL? {
        if let url = await loadLegacyItem(UTType.url) as? URL { return url }
        guard canLoadObject(ofClass: NSURL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
    }

    func loadText() async -> String? {
        if let text = await loadLegacyItem(UTType.plainText) as? String { return text }
        guard canLoadObject(ofClass: NSString.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
    }

    private func loadLegacyItem(_ type: UTType) async -> (any NSSecureCoding)? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                nonisolated(unsafe) let item = item
                continuation.resume(returning: item)
            }
        }
    }
}
