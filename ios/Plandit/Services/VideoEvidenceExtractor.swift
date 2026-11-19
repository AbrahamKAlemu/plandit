import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers
import Vision

struct VideoEvidence: Sendable {
    let text: String
    let transcriptionNotice: String?

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

/// Reads a video on the phone for place evidence. A protocol so tests can stand in for OCR and speech.
protocol VideoEvidenceReading: Sendable {
    func extract(from source: URL) async throws -> VideoEvidence
}

struct VideoEvidenceExtractor: VideoEvidenceReading {
    private static let maximumDuration: TimeInterval = 5 * 60
    private let mediaStore: TemporaryMediaStore

    init(mediaStore: TemporaryMediaStore = TemporaryMediaStore()) {
        self.mediaStore = mediaStore
    }

    /// Reads the video, then deletes Plandit's copy. A file already in `TemporaryMedia/` (a shared
    /// video, or one picked in the app) is read there; anything else is copied in first. Either way
    /// it's moved into `Reading/` first, so the 24-hour cleanup leaves it alone mid-read.
    func extract(from source: URL) async throws -> VideoEvidence {
        let staged: URL
        if mediaStore.contains(source) {
            try mediaStore.validate(source)
            staged = source
        } else {
            staged = try mediaStore.stage(source)
        }
        let reading: URL
        do {
            reading = try mediaStore.claimForReading(staged)
        } catch {
            try? mediaStore.remove(staged)
            throw error
        }
        defer { try? mediaStore.remove(reading) }

        let asset = AVURLAsset(url: reading)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration <= Self.maximumDuration else {
            throw VideoEvidenceError.tooLong
        }

        let frameText = try await recognizeFrameText(asset: asset, duration: duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var transcriptionNotice: String?
        let transcript: String?
        if Self.shouldAttemptTranscription(audioTrackCount: audioTracks.count) {
            do {
                transcript = try await transcribe(
                    url: reading,
                    contextualStrings: frameText
                )
                if transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    transcriptionNotice = "Audio transcription was unavailable. Review the visible text or add the spoken place details."
                }
            } catch {
                transcript = nil
                transcriptionNotice = "Audio transcription was unavailable. Review the visible text or add the spoken place details."
            }
        } else {
            transcript = nil
        }
        let combined = VideoEvidence.combine(frameText: frameText, transcript: transcript)
        guard !combined.isEmpty else { throw VideoEvidenceError.noEvidence }
        return VideoEvidence(
            text: combined,
            transcriptionNotice: transcriptionNotice
        )
    }

    static func shouldAttemptTranscription(audioTrackCount: Int) -> Bool {
        audioTrackCount > 0
    }

    /// Runs off the main actor: AVAssetImageGenerator isn't Sendable and its async API hops threads,
    /// so the generator must live and die on one background task.
    @concurrent
    private nonisolated func recognizeFrameText(asset: AVAsset, duration: TimeInterval) async throws -> [String] {
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

    private func transcribe(
        url: URL,
        contextualStrings: [String]
    ) async throws -> String? {
        let authorization = await speechAuthorization()
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable else {
            return nil
        }

        if recognizer.supportsOnDeviceRecognition,
           let transcript = try? await recognize(
               url: url,
               recognizer: recognizer,
               contextualStrings: contextualStrings,
               requiresOnDeviceRecognition: true
           ),
           !transcript.isEmpty {
            return transcript
        }

#if DEBUG && targetEnvironment(simulator)
        return try await recognize(
            url: url,
            recognizer: recognizer,
            contextualStrings: contextualStrings,
            requiresOnDeviceRecognition: false
        )
#else
        return nil
#endif
    }

    private func recognize(
        url: URL,
        recognizer: SFSpeechRecognizer,
        contextualStrings: [String],
        requiresOnDeviceRecognition: Bool
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
            request.contextualStrings = contextualStrings
                .flatMap { $0.components(separatedBy: .newlines) }
                .filter { !$0.isEmpty }
                .prefix(100)
                .map { $0 }
            request.taskHint = .dictation
            var resumed = false
            var latestTranscript = ""
            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    latestTranscript = result.bestTranscription.formattedString
                }
                if let error, !resumed {
                    resumed = true
                    if latestTranscript.isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: latestTranscript)
                    }
                } else if let result, result.isFinal, !resumed {
                    resumed = true
                    continuation.resume(returning: latestTranscript)
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
