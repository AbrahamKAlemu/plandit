import Foundation

enum LinkParser {
    /// The first web link in a blob of shared text. TikTok often shares "caption… https://vm.tiktok.com/…",
    /// and a bare "tiktok.com/@creator/video/…" is detected too.
    static func firstWebURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }
}

/// Where a saved post came from. Brand names appear as text only; never use platform logos as icons.
enum SourcePlatform: String, Codable, CaseIterable, Sendable {
    case tiktok, instagram, video, web

    init(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        if host.hasSuffix("tiktok.com") {
            self = .tiktok
        } else if host.hasSuffix("instagram.com") {
            self = .instagram
        } else {
            self = .web
        }
    }

    var displayName: String {
        switch self {
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .video: "Video"
        case .web: "Web link"
        }
    }

    /// "this TikTok", "this Reel", "this page".
    var postPhrase: String {
        switch self {
        case .tiktok: "this TikTok"
        case .instagram: "this Reel"
        case .video: "this video"
        case .web: "this page"
        }
    }
}
