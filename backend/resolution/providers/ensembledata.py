import html
import json
import re
from dataclasses import dataclass
from typing import Callable
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener, urlopen

from resolution.url_policy import SourceUrlError, parse_supported_source_url

ENSEMBLEDATA_POST_INFO_URL = "https://ensembledata.com/apis/tt/post/info"
ALLOWED_SUBTITLE_HOSTS = {"v16m-default.akamaized.net"}
ALLOWED_SUBTITLE_HOST_SUFFIXES = (
    ".tiktokcdn.com",
    ".tiktokcdn-eu.com",
    ".tiktokv.com",
    ".byteoversea.com",
    ".ibytedtos.com",
)


class EnsembleDataError(RuntimeError):
    pass


@dataclass(frozen=True)
class SocialEvidence:
    canonical_url: str
    caption: str | None
    transcript: str | None
    transcript_language: str | None

    @property
    def text(self) -> str:
        return "\n".join(
            part for part in (self.caption, self.transcript) if part
        )


class EnsembleDataClient:
    def __init__(
        self,
        token: str,
        *,
        fetch_json: Callable[[str], object] | None = None,
        fetch_text: Callable[[str], str] | None = None,
        resolve_url: Callable[[str], str] | None = None,
        validate_subtitle_url: Callable[[str], None] | None = None,
    ):
        if not token:
            raise ValueError("EnsembleData token is required")
        self.token = token
        self.fetch_json = fetch_json or _fetch_json
        self.fetch_text = fetch_text or _fetch_text
        self.resolve_url = resolve_url or resolve_tiktok_share_url
        self.validate_subtitle_url = validate_subtitle_url or _validate_external_https_url

    def evidence_for(self, source_url: str) -> SocialEvidence:
        canonical_url = self.resolve_url(source_url)
        supported = parse_supported_source_url(canonical_url)
        if supported.platform != "tiktok" or not _is_full_tiktok_video_url(
            supported.canonical_url
        ):
            raise EnsembleDataError("TikTok share URL did not resolve to a video URL")

        query = urlencode(
            {
                "url": supported.canonical_url,
                "token": self.token,
                "new_version": "false",
                "download_video": "false",
            }
        )
        payload = self.fetch_json(f"{ENSEMBLEDATA_POST_INFO_URL}?{query}")
        caption = _find_first_string(
            payload,
            {"desc", "description", "video_description"},
        )
        subtitle = _find_subtitle(payload)
        transcript = None
        language = None
        if subtitle:
            subtitle_url, language = subtitle
            self.validate_subtitle_url(subtitle_url)
            transcript = parse_subtitle_text(self.fetch_text(subtitle_url))

        return SocialEvidence(
            canonical_url=supported.canonical_url,
            caption=caption,
            transcript=transcript or None,
            transcript_language=language,
        )


class _TikTokRedirectHandler(HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _validate_tiktok_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class _ExternalRedirectHandler(HTTPRedirectHandler):
    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _validate_external_https_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def resolve_tiktok_share_url(value: str) -> str:
    supported = parse_supported_source_url(value)
    if supported.platform != "tiktok":
        raise EnsembleDataError("Only TikTok URLs are supported")
    if _is_full_tiktok_video_url(supported.canonical_url):
        return supported.canonical_url

    opener = build_opener(_TikTokRedirectHandler())
    request = Request(
        supported.canonical_url,
        headers={"User-Agent": "Plandit/0.1 URL resolver"},
    )
    try:
        with opener.open(request, timeout=15) as response:
            final_url = response.geturl()
    except (HTTPError, OSError) as error:
        raise EnsembleDataError("Unable to resolve TikTok share URL") from error

    _validate_tiktok_url(final_url)
    final = parse_supported_source_url(final_url)
    if not _is_full_tiktok_video_url(final.canonical_url):
        raise EnsembleDataError("TikTok share URL did not resolve to a video")
    return final.canonical_url


def parse_subtitle_text(value: str) -> str:
    stripped = value.strip()
    if not stripped:
        return ""
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError:
        return _parse_timed_text(stripped)

    lines = _collect_transcript_lines(payload)
    return _deduplicate_lines(lines)


def _fetch_json(url: str) -> object:
    request = Request(url, headers={"Accept": "application/json"})
    try:
        with urlopen(request, timeout=20) as response:
            return json.load(response)
    except (HTTPError, OSError, json.JSONDecodeError) as error:
        raise EnsembleDataError("EnsembleData request failed") from error


def _fetch_text(url: str) -> str:
    request = Request(url, headers={"Accept": "application/json,text/vtt,text/plain"})
    try:
        opener = build_opener(_ExternalRedirectHandler())
        with opener.open(request, timeout=20) as response:
            return response.read().decode("utf-8", errors="replace")
    except (HTTPError, OSError) as error:
        raise EnsembleDataError("Subtitle request failed") from error


def _find_first_string(value: object, keys: set[str]) -> str | None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in keys and isinstance(item, str) and item.strip():
                return item.strip()
        for item in value.values():
            result = _find_first_string(item, keys)
            if result:
                return result
    elif isinstance(value, list):
        for item in value:
            result = _find_first_string(item, keys)
            if result:
                return result
    return None


def _find_subtitle(value: object) -> tuple[str, str | None] | None:
    if isinstance(value, dict):
        caption_infos = value.get("caption_infos")
        if isinstance(caption_infos, list):
            entries = [
                item
                for item in caption_infos
                if isinstance(item, dict) and isinstance(item.get("url"), str)
            ]
            preferred = next(
                (
                    item
                    for item in entries
                    if str(
                        item.get("language_code")
                        or item.get("language")
                        or item.get("lang")
                        or ""
                    ).lower().startswith("en")
                ),
                entries[0] if entries else None,
            )
            if preferred:
                language = (
                    preferred.get("language_code")
                    or preferred.get("language")
                    or preferred.get("lang")
                )
                return preferred["url"], str(language) if language else None
        for item in value.values():
            result = _find_subtitle(item)
            if result:
                return result
    elif isinstance(value, list):
        for item in value:
            result = _find_subtitle(item)
            if result:
                return result
    return None


def _collect_transcript_lines(value: object) -> list[str]:
    if isinstance(value, dict):
        for key in ("utterances", "captions", "segments"):
            if isinstance(value.get(key), list):
                return _collect_transcript_lines(value[key])
        lines = []
        for key in ("text", "content", "utterance"):
            item = value.get(key)
            if isinstance(item, str) and item.strip():
                lines.append(item.strip())
        if lines:
            return lines
        for item in value.values():
            lines.extend(_collect_transcript_lines(item))
        return lines
    if isinstance(value, list):
        lines = []
        for item in value:
            lines.extend(_collect_transcript_lines(item))
        return lines
    return []


def _parse_timed_text(value: str) -> str:
    lines = []
    for raw_line in value.splitlines():
        line = re.sub(r"<[^>]+>", "", html.unescape(raw_line)).strip()
        if (
            not line
            or line.upper() == "WEBVTT"
            or "-->" in line
            or line.isdigit()
            or line.startswith(("NOTE", "STYLE", "REGION"))
        ):
            continue
        lines.append(line)
    return _deduplicate_lines(lines)


def _deduplicate_lines(lines: list[str]) -> str:
    seen = set()
    result = []
    for line in lines:
        normalized = " ".join(line.split())
        key = normalized.casefold()
        if normalized and key not in seen:
            seen.add(key)
            result.append(normalized)
    return "\n".join(result)


def _validate_tiktok_url(value: str) -> None:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower().rstrip(".")
    try:
        port = parsed.port
    except ValueError as error:
        raise EnsembleDataError("TikTok redirect used an invalid port") from error
    if (
        parsed.scheme.lower() != "https"
        or parsed.username
        or parsed.password
        or port not in (None, 443)
        or not (host == "tiktok.com" or host.endswith(".tiktok.com"))
    ):
        raise EnsembleDataError("TikTok redirect left the supported host")


def _validate_external_https_url(value: str) -> None:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").lower().rstrip(".")
    try:
        port = parsed.port
    except ValueError as error:
        raise EnsembleDataError("Subtitle URL used an invalid port") from error
    if (
        parsed.scheme.lower() != "https"
        or parsed.username
        or parsed.password
        or port not in (None, 443)
        or not host
        or host == "localhost"
        or host.endswith(".local")
        or not (
            host in ALLOWED_SUBTITLE_HOSTS
            or host.endswith(ALLOWED_SUBTITLE_HOST_SUFFIXES)
        )
    ):
        raise EnsembleDataError("Unsafe subtitle URL")


def _is_full_tiktok_video_url(value: str) -> bool:
    return re.fullmatch(
        r"https://(?:[^/]+\.)?tiktok\.com/@[^/]+/video/[^/]+",
        value,
    ) is not None
