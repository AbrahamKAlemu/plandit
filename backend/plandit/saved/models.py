import uuid
from urllib.parse import urlsplit

from django.db import models


class SourcePlatform(models.TextChoices):
    TIKTOK = "tiktok", "TikTok"
    INSTAGRAM = "instagram", "Instagram"
    WEB = "web", "Web link"

    @classmethod
    def from_url(cls, url: str) -> "SourcePlatform":
        host = (urlsplit(url).hostname or "").lower()
        if host == "tiktok.com" or host.endswith(".tiktok.com"):
            return cls.TIKTOK
        if host == "instagram.com" or host.endswith(".instagram.com"):
            return cls.INSTAGRAM
        return cls.WEB


class ExtractionStatus(models.TextChoices):
    PROCESSING = "processing", "Processing"  # waiting on metadata + place matching
    READY = "ready", "Ready"  # place found and confirmed
    NEEDS_REVIEW = "needs_review", "Needs review"  # place found, but hours/price/location need a human check
    FAILED = "failed", "Failed"  # no place found in the post


class SavedPost(models.Model):
    """A TikTok, Reel or link a user shared into Plandit, plus whatever we extracted from it."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey("core.Profile", on_delete=models.CASCADE, related_name="saved_posts")
    url = models.URLField(max_length=1000)
    platform = models.CharField(max_length=20, choices=SourcePlatform.choices)
    creator_handle = models.CharField(max_length=80, blank=True)
    caption = models.TextField(blank=True)
    thumbnail_url = models.URLField(max_length=1000, blank=True)
    saved_at = models.DateTimeField(auto_now_add=True)
    status = models.CharField(max_length=20, choices=ExtractionStatus.choices, default=ExtractionStatus.PROCESSING)
    place = models.ForeignKey(
        "places.Place", on_delete=models.SET_NULL, null=True, blank=True, related_name="saved_posts"
    )
    estimated_cost = models.DecimalField(max_digits=8, decimal_places=2, null=True, blank=True)
    tags = models.JSONField(default=list, blank=True)
    failure_reason = models.CharField(max_length=200, blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-saved_at"]
        constraints = [models.UniqueConstraint(fields=["owner", "url"], name="saved_unique_owner_url")]
        indexes = [models.Index(fields=["owner", "status"])]

    def __str__(self) -> str:
        return self.place.name if self.place else self.url

    @property
    def is_mappable(self) -> bool:
        """Has a place we can pin and add to a plan."""
        return self.place_id is not None and self.status in {ExtractionStatus.READY, ExtractionStatus.NEEDS_REVIEW}
