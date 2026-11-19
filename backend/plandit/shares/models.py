import secrets

from django.db import models

from plandit.core.models import Profile

SLUG_LENGTH = 10


def new_slug() -> str:
    """10 URL-safe characters (~60 bits): short enough to paste, too many to guess."""
    return secrets.token_urlsafe(16)[:SLUG_LENGTH]


class SharedPlan(models.Model):
    """A day plan someone chose to share as a link (plandit.app/p/<slug>). Anyone with the link can
    view it; only the owner can update it or stop sharing (which deletes the row). One link per
    plan: sharing the same plan again updates it, so friends always see the latest version.

    `data` is what the page shows, already formatted by the app in the owner's time zone and
    language (see SharedPlanSerializer for the shape)."""

    slug = models.CharField(max_length=SLUG_LENGTH, unique=True, default=new_slug, editable=False)
    owner = models.ForeignKey(Profile, on_delete=models.CASCADE, related_name="shared_plans")
    plan_id = models.UUIDField(help_text="The app's DayPlan id.")
    data = models.JSONField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["owner", "plan_id"], name="one_link_per_plan")]

    def __str__(self) -> str:
        return f"{self.slug}: {self.data.get('title', '')}"
