import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers
import Vision

enum VideoEvidenceError: LocalizedError {
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

struct VideoEvidence: Sendable {
    let text: String

    static func combine(frameText: [String], transcript: String?) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        let inputs = frameText + [transcript].compactMap { $0 }

        for input in inputs {
            for rawLine in input.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard line.count >= 2, seen.insert(key).inserted else { continue }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct TemporaryMediaStore {
    private static let maximumBytes: Int64 = 250 * 1024 * 1024
    let root: URL

    init(root: URL? = nil) {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) ?? FileManager.default.temporaryDirectory
        self.root = root ?? base.appending(path: "TemporaryMedia", directoryHint: .isDirectory)
    }

    func stage(_ source: URL) throws -> URL {
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }

        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let contentType = values.contentType, contentType.conforms(to: .movie) else {
            throw VideoEvidenceError.unsupportedType
        }
        if let fileSize = values.fileSize, Int64(fileSize) > Self.maximumBytes {
            throw VideoEvidenceError.tooLarge
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let extensionName = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = root.appending(path: "\(UUID().uuidString).\(extensionName)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func remove(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

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
}

struct VideoEvidenceExtractor {
    private static let maximumDuration: TimeInterval = 5 * 60
    private let mediaStore: TemporaryMediaStore

    init(mediaStore: TemporaryMediaStore = TemporaryMediaStore()) {
        self.mediaStore = mediaStore
    }

    func extract(from source: URL) async throws -> VideoEvidence {
        let staged = try mediaStore.stage(source)
        defer { try? mediaStore.remove(staged) }

        let asset = AVURLAsset(url: staged)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration <= Self.maximumDuration else {
            throw VideoEvidenceError.tooLong
        }

        let frameText = try await recognizeFrameText(asset: asset, duration: duration)
        let transcript = try? await transcribeOnDevice(url: staged)
        let combined = VideoEvidence.combine(frameText: frameText, transcript: transcript)
        guard !combined.isEmpty else { throw VideoEvidenceError.noEvidence }
        return VideoEvidence(text: combined)
    }

    private func recognizeFrameText(asset: AVAsset, duration: TimeInterval) async throws -> [String] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let fractions: [Double] = duration < 2 ? [0.5] : [0.05, 0.25, 0.5, 0.75, 0.95]
        var results: [String] = []

        for fraction in fractions {
            let seconds = max(0, duration * fraction)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            if !text.isEmpty { results.append(text) }
        }
        return results
    }

    private func transcribeOnDevice(url: URL) async throws -> String? {
        let authorization = await speechAuthorization()
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            return nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !resumed {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal, !resumed {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
