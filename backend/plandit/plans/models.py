import uuid
from datetime import timedelta
from decimal import Decimal

from django.db import models


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
