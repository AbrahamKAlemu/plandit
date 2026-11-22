import secrets
import uuid

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


# Brief GS-5: friends' answers are deleted this many days after the plan's date (or with the link).
ANSWER_RETENTION_DAYS = 30


class ShareAnswer(models.Model):
    """A friend's answer on a shared plan's page (group plans, mode 1): "I'm in" or "Can't make it",
    a first name, and the stops they'd swap. No account: the same browser is recognized by its `pa`
    cookie, of which only the hash is stored (plandit.core.public_forms.responder_token).

    Only the organizer sees every answer (GET /api/shares/<slug>/answers/). The page shows how many
    are in and up to 3 of their first names, never who can't make it. Answers go with the link
    (CASCADE, brief GV-10) and 30 days after the plan's date (`plan_date`, brief GS-5)."""

    class Status(models.TextChoices):
        IN = "in"
        OUT = "out"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    shared_plan = models.ForeignKey(SharedPlan, on_delete=models.CASCADE, related_name="answers")
    responder = models.CharField(max_length=64, help_text="SHA-256 hex of the browser's cookie token.")
    name = models.CharField(max_length=30, help_text="First name, checked by clean_first_name.")
    status = models.CharField(max_length=3, choices=Status.choices)
    swaps = models.JSONField(
        default=dict, blank=True, help_text="{stop id: alternate id or null}, ids from the shared plan."
    )
    plan_date = models.DateField(db_index=True, help_text="The plan's day (SharedPlan.data['date']), for expiry.")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=["shared_plan", "responder"], name="one_answer_per_browser")]

    def __str__(self) -> str:
        return f"{self.shared_plan_id}: {self.status}"
