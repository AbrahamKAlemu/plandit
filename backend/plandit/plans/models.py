import uuid
from datetime import timedelta
from decimal import Decimal

from django.db import models

from plandit.shares.models import new_slug


class DayPlan(models.Model):
    """One Plandit day: an ordered set of stops with the travel between them."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    owner = models.ForeignKey("core.Profile", on_delete=models.CASCADE, related_name="plans")
    date = models.DateField()
    title = models.CharField(max_length=120, default="Today")
    budget = models.DecimalField(max_digits=8, decimal_places=2, default=60)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["-date"]
        constraints = [models.UniqueConstraint(fields=["owner", "date"], name="plan_unique_owner_date")]

    def __str__(self) -> str:
        return f"{self.title} ({self.date})"

    @property
    def total_cost(self) -> Decimal:
        stops = sum((stop.estimated_cost for stop in self.stops.all()), Decimal(0))
        legs = sum((leg.cost for leg in self.legs.all()), Decimal(0))
        return stops + legs

    @property
    def walking_miles(self) -> float:
        return round(sum(leg.miles for leg in self.legs.all() if leg.mode == TravelMode.WALK), 2)


class StopStatus(models.TextChoices):
    DONE = "done", "Done"
    NOW = "now", "Now"
    UPCOMING = "upcoming", "Planned"


class PlanStop(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    plan = models.ForeignKey(DayPlan, on_delete=models.CASCADE, related_name="stops")
    place = models.ForeignKey("places.Place", on_delete=models.PROTECT, related_name="+")
    position = models.PositiveSmallIntegerField()
    start = models.DateTimeField()
    duration_minutes = models.PositiveSmallIntegerField(default=60)
    estimated_cost = models.DecimalField(max_digits=8, decimal_places=2, default=0)
    note = models.TextField(blank=True)  # why the planner picked this stop
    source_post = models.ForeignKey(
        "saved.SavedPost", on_delete=models.SET_NULL, null=True, blank=True, related_name="plan_stops"
    )
    status = models.CharField(max_length=10, choices=StopStatus.choices, default=StopStatus.UPCOMING)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["position", "start"]

    def __str__(self) -> str:
        return f"{self.position + 1}. {self.place.name}"

    @property
    def end(self):
        return self.start + timedelta(minutes=self.duration_minutes)


class TravelMode(models.TextChoices):
    WALK = "walk", "Walk"
    SUBWAY = "subway", "Subway"
    BUS = "bus", "Bus"


class TravelLeg(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    plan = models.ForeignKey(DayPlan, on_delete=models.CASCADE, related_name="legs")
    from_stop = models.ForeignKey(PlanStop, on_delete=models.CASCADE, related_name="legs_out")
    to_stop = models.ForeignKey(PlanStop, on_delete=models.CASCADE, related_name="legs_in")
    mode = models.CharField(max_length=10, choices=TravelMode.choices)
    minutes = models.PositiveSmallIntegerField()
    miles = models.FloatField()
    cost = models.DecimalField(max_digits=6, decimal_places=2, default=0)
    detail = models.CharField(max_length=80, blank=True)  # "M4 bus", "4 and 7 trains"

    class Meta:
        ordering = ["from_stop__position"]

    def __str__(self) -> str:
        return f"{self.mode} {self.minutes} min"


# --- Friends' input links (group plans, mode 2) ------------------------------------------------

# Brief GS-5: friends' answers are deleted this many days after the plan's day (or with the link).
REQUEST_RETENTION_DAYS = 30
BUDGET_MAX = 150  # brief GI-2: $0 to $150, train included
MAX_STARS = 3  # brief GI-2


class GroupRequest(models.Model):
    """An "Ask friends what works" link (plandit.app/g/<slug>, group plans mode 2): the organizer's
    places, day, time range and answer deadline. Friends answer on the page without an account;
    the organizer's app reads the answers and builds the plan on the phone, then shares it with
    this request's slug, which marks it built and makes the link open that plan's page (brief GI-7).

    `status` is what the organizer did: `open` until they close it or build the plan. The link also
    stops taking answers at `answers_by` (brief GI-3). The request and its answers are deleted 30
    days after `day` (brief GS-5, plandit.core.retention) or when the organizer deletes it."""

    class Status(models.TextChoices):
        OPEN = "open"
        CLOSED = "closed"
        BUILT = "built"

    slug = models.CharField(max_length=10, unique=True, default=new_slug, editable=False)
    owner = models.ForeignKey("core.Profile", on_delete=models.CASCADE, related_name="plan_requests")
    places = models.JSONField(help_text="2 to 10 of {id, name, neighborhood, kind, costText}, from the app.")
    day = models.DateField(db_index=True, help_text="The plan's day, for expiry.")
    window_start = models.TimeField(help_text="Local time in time_zone.")
    window_end = models.TimeField(help_text="Local time in time_zone.")
    time_zone = models.CharField(max_length=64, help_text="IANA name, such as America/New_York.")
    answers_by = models.DateTimeField()
    status = models.CharField(max_length=6, choices=Status.choices, default=Status.OPEN)
    shared_plan = models.ForeignKey(
        "shares.SharedPlan",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="plan_requests",
        help_text="The plan built from the answers, once the app shares it with this request.",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"{self.slug}: {self.day} ({self.status})"


class GroupAnswer(models.Model):
    """A friend's answer on a /g/ link: a first name, a budget, when they're free and up to 3
    starred places. No account: the same browser is recognized by its `pa` cookie, of which only
    the hash is stored (plandit.core.public_forms.responder_token). Only the organizer sees answers
    (brief GI-4); the page shows other friends only how many have answered (brief GI-8)."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    request = models.ForeignKey(GroupRequest, on_delete=models.CASCADE, related_name="answers")
    responder = models.CharField(max_length=64, help_text="SHA-256 hex of the browser's cookie token.")
    name = models.CharField(max_length=30, help_text="First name, checked by clean_first_name.")
    budget = models.PositiveSmallIntegerField(help_text="Dollars for the day, train included.")
    free_from = models.TimeField()
    free_until = models.TimeField()
    stars = models.JSONField(default=list, blank=True, help_text="Up to 3 place ids from the request.")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["request", "responder"], name="one_request_answer_per_browser"),
            models.CheckConstraint(
                condition=models.Q(budget__lte=BUDGET_MAX), name="request_answer_budget_at_most_150"
            ),
            models.CheckConstraint(
                condition=models.Q(free_from__lt=models.F("free_until")), name="request_answer_free_from_before_until"
            ),
        ]

    def __str__(self) -> str:
        return f"{self.request_id}: {self.budget}"
