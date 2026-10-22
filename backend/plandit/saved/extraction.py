"""
Turns a shared post into a place on the map.

Pipeline: public metadata (TikTok oEmbed, no key needed) -> text -> PlaceMatcher -> Place.
The default NameMatcher only recognises places already in the database. Replace it with an
LLM + places-API matcher by pointing PLANDIT_PLACE_MATCHER at a class with the same `match`
method. Extraction runs inline in the request for now (one HTTP call plus a query); move it
to a worker once the matcher gets slower.
"""

import logging
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Protocol
from urllib.parse import urlencode

import httpx
from django.conf import settings
from django.utils.module_loading import import_string

from plandit.places.models import Place

from .models import ExtractionStatus, SavedPost, SourcePlatform

log = logging.getLogger(__name__)


@dataclass
class Metadata:
    title: str | None = None
    author_handle: str | None = None
    thumbnail_url: str | None = None


class OEmbedClient:
    """Public post metadata. TikTok's oEmbed endpoint needs no key. Instagram's needs a Meta
    app token, so Instagram posts get no metadata until that is configured."""

    def __init__(self, timeout: float | None = None):
        self.timeout = timeout or settings.PLANDIT_OEMBED_TIMEOUT_SECONDS

    def metadata(self, url: str) -> Metadata | None:
        if SourcePlatform.from_url(url) != SourcePlatform.TIKTOK:
            return None
        endpoint = "https://www.tiktok.com/oembed?" + urlencode({"url": url})
        response = httpx.get(endpoint, timeout=self.timeout, follow_redirects=True)
        response.raise_for_status()
        data = response.json()
        handle = data.get("author_unique_id")
        return Metadata(
            title=data.get("title") or None,
            author_handle=f"@{handle}" if handle else None,
            thumbnail_url=data.get("thumbnail_url") or None,
        )


@dataclass
class Match:
    place: Place
    estimated_cost: Decimal | None = None
    tags: list[str] = field(default_factory=list)
    needs_review: bool = False


class PlaceMatcher(Protocol):
    def match(self, text: str) -> Match | None: ...


class NameMatcher:
    """Finds a known Place whose name appears in the post text. The longest name wins.
    Flags the match for review when we don't know the place's hours."""

    def match(self, text: str) -> Match | None:
        haystack = text.lower()
        if not haystack.strip():
            return None
        best: Place | None = None
        for place in Place.objects.all().iterator():
            if place.name.lower() in haystack and (best is None or len(place.name) > len(best.name)):
                best = place
        if best is None:
            return None
        return Match(place=best, needs_review=best.hours is None)


def get_matcher() -> PlaceMatcher:
    return import_string(settings.PLANDIT_PLACE_MATCHER)()


@dataclass
class ExtractionResult:
    creator_handle: str | None = None
    caption: str | None = None
    thumbnail_url: str | None = None
    place: Place | None = None
    estimated_cost: Decimal | None = None
    tags: list[str] = field(default_factory=list)
    needs_review: bool = False
    failure_reason: str = ""


def extract(
    post: SavedPost, *, oembed: OEmbedClient | None = None, matcher: PlaceMatcher | None = None
) -> ExtractionResult:
    oembed = oembed or OEmbedClient()
    matcher = matcher or get_matcher()

    metadata: Metadata | None = None
    try:
        metadata = oembed.metadata(post.url)
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("oEmbed lookup failed for %s: %s", post.url, exc)

    caption = (metadata.title if metadata else None) or post.caption or ""
    match = matcher.match(" ".join(part for part in [caption, post.url] if part))
    if match is None:
        return ExtractionResult(
            creator_handle=metadata.author_handle if metadata else None,
            caption=caption or None,
            thumbnail_url=metadata.thumbnail_url if metadata else None,
            failure_reason="No place found in the post.",
        )
    return ExtractionResult(
        creator_handle=metadata.author_handle if metadata else None,
        caption=caption or None,
        thumbnail_url=metadata.thumbnail_url if metadata else None,
        place=match.place,
        estimated_cost=match.estimated_cost,
        tags=match.tags,
        needs_review=match.needs_review,
    )


def apply(post: SavedPost, result: ExtractionResult) -> SavedPost:
    post.creator_handle = result.creator_handle or post.creator_handle
    post.caption = result.caption or post.caption
    post.thumbnail_url = result.thumbnail_url or post.thumbnail_url
    post.place = result.place
    post.estimated_cost = result.estimated_cost
    post.tags = result.tags
    post.failure_reason = result.failure_reason
    if result.place is None:
        post.status = ExtractionStatus.FAILED
    elif result.needs_review:
        post.status = ExtractionStatus.NEEDS_REVIEW
    else:
        post.status = ExtractionStatus.READY
    post.save()
    return post


def run_extraction(post: SavedPost) -> SavedPost:
    try:
        return apply(post, extract(post))
    except Exception:  # noqa: BLE001 - a crashed extraction must never leave a post stuck in "processing"
        log.exception("Extraction crashed for saved post %s", post.id)
        post.status = ExtractionStatus.FAILED
        post.failure_reason = "Something went wrong while reading the post."
        post.save(update_fields=["status", "failure_reason", "updated_at"])
        return post
