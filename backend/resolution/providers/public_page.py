import http.client
import ipaddress
import json
import queue
import socket
import ssl
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

from resolution.url_policy import parse_supported_source_url

MAX_PAGE_BYTES = 2_000_000
MAX_REDIRECTS = 5
REQUEST_TIMEOUT_SECONDS = 15
USER_AGENT = "Mozilla/5.0"


class PublicPageError(RuntimeError):
    pass


class PublicPageEvidenceMissing(PublicPageError):
    pass


@dataclass(frozen=True)
class PublicPageSocialEvidence:
    canonical_url: str
    caption: str
    transcript: str | None = None
    transcript_language: str | None = None

    @property
    def text(self) -> str:
        return "\n".join(part for part in (self.caption, self.transcript) if part)


class PublicPageSocialEvidenceClient:
    def __init__(
        self,
        *,
        fetch_page: Callable[[str], tuple[str, str]] | None = None,
    ):
        self.fetch_page = fetch_page or _fetch_page

    def evidence_for(self, source_url: str) -> PublicPageSocialEvidence:
        supported = parse_supported_source_url(source_url)
        final_url, page = self.fetch_page(supported.canonical_url)
        final = parse_supported_source_url(final_url)
        if final.platform != supported.platform:
            raise PublicPageError("Social URL redirected to another platform")

        if final.platform == "tiktok":
            caption = _parse_tiktok_caption(page)
        else:
            caption = _parse_instagram_caption(page)
        if not caption:
            raise PublicPageEvidenceMissing("Public page did not expose a caption")

        return PublicPageSocialEvidence(
            canonical_url=final.canonical_url,
            caption=caption,
        )


@dataclass(frozen=True)
class _PageResponse:
    status: int
    location: str | None
    body: bytes


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host: str, address: str, timeout: float):
        super().__init__(
            host,
            port=443,
            timeout=timeout,
            context=ssl.create_default_context(),
        )
        self.address = address

    def connect(self):
        self.sock = socket.create_connection(
            (self.address, self.port),
            self.timeout,
            self.source_address,
        )
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)


class _SocialPageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.meta: dict[str, str] = {}
        self.hydration_parts: list[str] = []
        self._reading_hydration = False

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "meta":
            key = values.get("property") or values.get("name")
            content = values.get("content")
            if key and content:
                self.meta[key.lower()] = content
        elif tag == "script" and values.get("id") == "__UNIVERSAL_DATA_FOR_REHYDRATION__":
            self._reading_hydration = True

    def handle_endtag(self, tag):
        if tag == "script":
            self._reading_hydration = False

    def handle_data(self, data):
        if self._reading_hydration:
            self.hydration_parts.append(data)


def _fetch_page(url: str) -> tuple[str, str]:
    initial = parse_supported_source_url(url)
    current_url = initial.canonical_url
    deadline = time.monotonic() + REQUEST_TIMEOUT_SECONDS
    for redirect_count in range(MAX_REDIRECTS + 1):
        _remaining_time(deadline)
        current = parse_supported_source_url(current_url)
        if current.platform != initial.platform:
            raise PublicPageError("Social URL redirected to another platform")
        response = _open_pinned(current.canonical_url, deadline=deadline)
        if response.status in {301, 302, 303, 307, 308}:
            if redirect_count == MAX_REDIRECTS or not response.location:
                raise PublicPageError("Public social page exceeded the redirect limit")
            redirected = parse_supported_source_url(urljoin(current.canonical_url, response.location))
            if redirected.platform != initial.platform:
                raise PublicPageError("Social URL redirected to another platform")
            current_url = redirected.canonical_url
            continue
        if not 200 <= response.status < 300:
            raise PublicPageError("Unable to read the public social page")
        return current.canonical_url, response.body.decode("utf-8", errors="replace")
    raise PublicPageError("Public social page exceeded the redirect limit")


def _open_pinned(url: str, *, deadline: float | None = None) -> _PageResponse:
    deadline = deadline or time.monotonic() + REQUEST_TIMEOUT_SECONDS
    parsed = urlsplit(url)
    host = parsed.hostname
    if not host:
        raise PublicPageError("Public social page host is missing")
    path = parsed.path or "/"
    if parsed.query:
        path += f"?{parsed.query}"

    last_error = None
    for address in _public_addresses(host, deadline=deadline):
        connection = _PinnedHTTPSConnection(host, address, _remaining_time(deadline))
        try:
            connection.connect()
            if connection.sock:
                connection.sock.settimeout(_remaining_time(deadline))
            connection.request(
                "GET",
                path,
                headers={
                    "Accept": "text/html,application/xhtml+xml",
                    "Accept-Encoding": "identity",
                    "User-Agent": USER_AGENT,
                },
            )
            if connection.sock:
                connection.sock.settimeout(_remaining_time(deadline))
            response = connection.getresponse()
            if connection.sock:
                connection.sock.settimeout(_remaining_time(deadline))
            content_length = response.getheader("Content-Length")
            if content_length and int(content_length) > MAX_PAGE_BYTES:
                raise PublicPageError("Public social page exceeded the size limit")
            body = response.read(MAX_PAGE_BYTES + 1)
            if len(body) > MAX_PAGE_BYTES:
                raise PublicPageError("Public social page exceeded the size limit")
            if response.getheader("Content-Encoding") not in {None, "identity"}:
                raise PublicPageError("Public social page used unsupported compression")
            return _PageResponse(response.status, response.getheader("Location"), body)
        except (OSError, ssl.SSLError, http.client.HTTPException, ValueError) as error:
            last_error = error
        finally:
            connection.close()
    raise PublicPageError("Unable to read the public social page") from last_error


def _public_addresses(host: str, *, deadline: float | None = None) -> list[str]:
    deadline = deadline or time.monotonic() + REQUEST_TIMEOUT_SECONDS
    result_queue = queue.Queue(maxsize=1)

    def resolve():
        try:
            result_queue.put((socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM), None))
        except OSError as error:
            result_queue.put((None, error))

    threading.Thread(target=resolve, daemon=True).start()
    try:
        records, error = result_queue.get(timeout=_remaining_time(deadline))
    except queue.Empty as error:
        raise PublicPageError("Public social page resolution timed out") from error
    if error:
        raise PublicPageError("Unable to resolve the public social page") from error
    addresses = []
    for record in records:
        address = record[4][0]
        if not ipaddress.ip_address(address).is_global:
            raise PublicPageError("Social page resolved to a non-public address")
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise PublicPageError("Social page did not resolve to a public address")
    return addresses


def _remaining_time(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise PublicPageError("Public social page request timed out")
    return remaining


def _parse_tiktok_caption(page: str) -> str | None:
    parser = _SocialPageParser()
    parser.feed(page)
    raw_payload = "".join(parser.hydration_parts).strip()
    if not raw_payload:
        return None
    try:
        payload = json.loads(raw_payload)
    except json.JSONDecodeError as error:
        raise PublicPageError("TikTok metadata was malformed") from error

    detail = payload.get("__DEFAULT_SCOPE__", {}).get("webapp.video-detail", {})
    item = detail.get("itemInfo", {}).get("itemStruct", {})
    caption = item.get("desc") or detail.get("shareMeta", {}).get("desc")
    if not isinstance(caption, str):
        return None
    return caption.strip() or None


def _parse_instagram_caption(page: str) -> str | None:
    parser = _SocialPageParser()
    parser.feed(page)
    caption = parser.meta.get("og:description")
    if not caption:
        return None
    return caption.strip() or None
