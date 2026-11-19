import Foundation

enum LinkParser {
    /// The first web link in a blob of shared text. TikTok often shares "caption… https://vm.tiktok.com/…",
    /// and a bare "tiktok.com/@creator/video/…" is detected too.
    static func firstWebURL(in text: String) -> URL? {
        webURLs(in: text).first
    }

    /// Every web link in the text, in order.
    static func webURLs(in text: String) -> [URL] {
        links(in: text).map(\.url)
    }

    /// The text with its links taken out, or nil when nothing else is left. Captions show this, so
    /// a post's link never reads as its caption (W-12).
    static func textWithoutLinks(_ text: String?) -> String? {
        guard var remaining = text else { return nil }
        for link in links(in: remaining).reversed() {
            remaining.removeSubrange(link.range)
        }
        let cleaned = remaining
            .components(separatedBy: .newlines)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func links(in text: String) -> [(url: URL, range: Range<String.Index>)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text) else { return nil }
            return (url, range)
        }
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
