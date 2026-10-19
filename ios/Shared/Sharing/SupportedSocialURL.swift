import Foundation

enum SupportedSocialURLError: LocalizedError, Equatable {
    case insecure
    case credentials
    case port
    case unsupportedHost
    case unsupportedPath

    var errorDescription: String? {
        switch self {
        case .insecure:
            "Use an HTTPS TikTok or Instagram link."
        case .credentials, .port, .unsupportedHost, .unsupportedPath:
            "Use a TikTok video or Instagram Reel link."
        }
    }
}

struct SupportedSocialURL: Hashable, Codable {
    let originalURL: URL
    let canonicalURL: URL
    let platform: SourcePlatform

    init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw SupportedSocialURLError.insecure
        }
        guard url.user == nil, url.password == nil else {
            throw SupportedSocialURLError.credentials
        }
        guard url.port == nil || url.port == 443 else {
            throw SupportedSocialURLError.port
        }
        guard let host = url.host()?.lowercased() else {
            throw SupportedSocialURLError.unsupportedHost
        }

        let platform: SourcePlatform
        if Self.isHost(host, under: "tiktok.com") {
            platform = .tiktok
            try Self.validateTikTok(path: url.path, host: host)
        } else if Self.isHost(host, under: "instagram.com") {
            platform = .instagram
            try Self.validateInstagram(path: url.path)
        } else {
            throw SupportedSocialURLError.unsupportedHost
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.host = host
        components?.port = nil
        components?.query = nil
        components?.fragment = nil
        let trimmedPath = url.path.count > 1 ? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : ""
        components?.path = trimmedPath.isEmpty ? "/" : "/\(trimmedPath)"
        guard let canonicalURL = components?.url else {
            throw SupportedSocialURLError.unsupportedPath
        }

        self.originalURL = url
        self.canonicalURL = canonicalURL
        self.platform = platform
    }

    private static func isHost(_ host: String, under root: String) -> Bool {
        host == root || host.hasSuffix(".\(root)")
    }

    private static func validateTikTok(path: String, host: String) throws {
        let shortHosts = ["vm.tiktok.com", "vt.tiktok.com"]
        if shortHosts.contains(host), path.count > 1 {
            return
        }
        let parts = path.split(separator: "/")
        guard parts.count >= 3,
              parts[0].hasPrefix("@"),
              parts[1] == "video",
              !parts[2].isEmpty else {
            throw SupportedSocialURLError.unsupportedPath
        }
    }

    private static func validateInstagram(path: String) throws {
        let parts = path.split(separator: "/")
        guard parts.count >= 2,
              ["reel", "reels", "p"].contains(String(parts[0]).lowercased()),
              !parts[1].isEmpty else {
            throw SupportedSocialURLError.unsupportedPath
        }
    }
}
