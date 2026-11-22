import Foundation

/// A group plan's invite link, `https://plandit.app/j/<token>` (architecture, "Mode 3: edit
/// together"). "Add a link" and the share sheet send these to the join sheet instead of place
/// finding; every other link (`/p/`, `/g/`, TikTok, Instagram, anything else) goes where it went.
enum InviteLink {
    /// Where invite links point: the site, and the API's own host, which makes them until the site
    /// forwards `/j/` (the server's `INVITE_BASE_URL` is blank until then, or `https://plandit.app`).
    static let hosts: Set<String> = ["plandit.app", "www.plandit.app", "plandit-api.onrender.com"]

    /// The server's tokens are 22 URL-safe characters. Any length from 16 to 64 is let through to
    /// ask the server, which says whether it works: a token cut short shows "This invite doesn't
    /// work any more" rather than place finding, and the fake server's longer tokens work.
    static let tokenLengths = 16...64

    /// The token of the first invite link in pasted or shared text: the link on its own (with or
    /// without `https://`), or inside a message. Nil when there's none.
    static func token(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(where: \.isWhitespace) {
            let typed = trimmed.contains("://") ? trimmed : "https://" + trimmed
            if let url = URL(string: typed), let token = token(in: url) { return token }
        }
        return LinkParser.webURLs(in: trimmed).lazy.compactMap { token(in: $0) }.first
    }

    /// The token when `url` is an invite link: http(s) on one of `hosts`, no other port or
    /// credentials, and the path `/j/<token>` with at most a trailing slash. Query and fragment
    /// don't matter.
    static func token(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil,
              let host = url.host()?.lowercased(), hosts.contains(host) else { return nil }
        if let port = url.port, port != (scheme == "https" ? 443 : 80) { return nil }
        var path = url.path(percentEncoded: true)
        if path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/j/") else { return nil }
        let token = String(path.dropFirst(3))
        return isToken(token) ? token : nil
    }

    /// Letters, digits, `-` and `_`, as `secrets.token_urlsafe` makes them.
    static func isToken(_ text: String) -> Bool {
        tokenLengths.contains(text.count) && text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }
}
