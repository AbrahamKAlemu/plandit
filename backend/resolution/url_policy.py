import re
from dataclasses import dataclass
from urllib.parse import SplitResult, urlsplit, urlunsplit


class SourceUrlError(ValueError):
    pass


@dataclass(frozen=True)
class SupportedSourceUrl:
    canonical_url: str
    platform: str


def parse_supported_source_url(value: str) -> SupportedSourceUrl:
    parsed = urlsplit(value)
    if parsed.scheme.lower() != "https":
        raise SourceUrlError("HTTPS is required")
    if parsed.username or parsed.password:
        raise SourceUrlError("URL credentials are not allowed")
    try:
        port = parsed.port
    except ValueError as error:
        raise SourceUrlError("Invalid port") from error
    if port not in (None, 443):
        raise SourceUrlError("Nonstandard ports are not allowed")
    if not parsed.hostname:
        raise SourceUrlError("Host is required")

    host = parsed.hostname.lower().rstrip(".")
    path = parsed.path.rstrip("/") or "/"
    if _host_under(host, "tiktok.com"):
        if host not in {"vm.tiktok.com", "vt.tiktok.com"} and not re.fullmatch(
            r"/(?:@[^/]+/video/[^/]+|t/[^/]+)", path
        ):
            raise SourceUrlError("Unsupported TikTok path")
        platform = "tiktok"
    elif _host_under(host, "instagram.com"):
        if not re.fullmatch(r"/(?:reel|reels|p)/[^/]+", path, flags=re.IGNORECASE):
            raise SourceUrlError("Unsupported Instagram path")
        platform = "instagram"
    else:
        raise SourceUrlError("Unsupported host")

    canonical = SplitResult("https", host, path, "", "")
    return SupportedSourceUrl(urlunsplit(canonical), platform)


def _host_under(host: str, root: str) -> bool:
    return host == root or host.endswith(f".{root}")
