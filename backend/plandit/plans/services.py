"""Plan mutations that keep stops and legs consistent. Travel legs are estimated the same way
the iOS scaffold does it until a real routing/transit service is wired in."""

import math
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from .models import DayPlan, PlanStop, TravelLeg, TravelMode

STREET_GRID_DETOUR = 1.25
WALK_LIMIT_MILES = 1.2
WALK_MINUTES_PER_MILE = 20
SUBWAY_FARE = Decimal("2.90")


def haversine_miles(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius_miles = 3958.8
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * radius_miles * math.asin(math.sqrt(a))


def estimate_leg(plan: DayPlan, a: PlanStop, b: PlanStop) -> TravelLeg:
    """Rough leg: walk under ~1.2 mi, otherwise subway."""
    miles = (
        haversine_miles(a.place.latitude, a.place.longitude, b.place.latitude, b.place.longitude) * STREET_GRID_DETOUR
    )
    miles = round(miles, 2)
    if miles <= WALK_LIMIT_MILES:
        return TravelLeg(
            plan=plan,
            from_stop=a,
            to_stop=b,
            mode=TravelMode.WALK,
            minutes=max(3, round(miles * WALK_MINUTES_PER_MILE)),
            miles=miles,
        )
    return TravelLeg(
        plan=plan,
        from_stop=a,
        to_stop=b,
        mode=TravelMode.SUBWAY,
        minutes=10 + round(miles * 4),
        miles=miles,
        cost=SUBWAY_FARE,
        detail="Subway",
    )


@transaction.atomic
def rebuild_legs(plan: DayPlan) -> None:
    """Keeps existing legs between consecutive stops and estimates any new pairs."""
    stops = list(plan.stops.select_related("place").order_by("position", "start"))
    existing = {(leg.from_stop_id, leg.to_stop_id): leg for leg in plan.legs.all()}
    keep: list = []
    for a, b in zip(stops, stops[1:], strict=False):
        leg = existing.get((a.id, b.id))
        if leg is None:
            leg = estimate_leg(plan, a, b)
            leg.save()
        keep.append(leg.id)
    plan.legs.exclude(id__in=keep).delete()


@transaction.atomic
def renumber(plan: DayPlan) -> None:
    for index, stop in enumerate(plan.stops.order_by("position", "start")):
        if stop.position != index:
            stop.position = index
            stop.save(update_fields=["position"])


@transaction.atomic
def append_stop(
    plan: DayPlan,
    *,
    place,
    duration_minutes: int = 60,
    estimated_cost: Decimal | None = None,
    note: str = "",
    source_post=None,
    start=None,
) -> PlanStop:
    """Appends a stop to the end of the day, 20 minutes after the previous stop ends."""
    last = plan.stops.order_by("-position").first()
    if start is None:
        start = (last.end if last else timezone.now()) + timedelta(minutes=20)
    stop = PlanStop.objects.create(
        plan=plan,
        place=place,
        position=(last.position + 1) if last else 0,
        start=start,
        duration_minutes=duration_minutes,
        estimated_cost=estimated_cost if estimated_cost is not None else Decimal(0),
        note=note,
        source_post=source_post,
    )
    rebuild_legs(plan)
    return stop


@transaction.atomic
def remove_stop(plan: DayPlan, stop: PlanStop) -> None:
    stop.delete()
    renumber(plan)
    rebuild_legs(plan)


@transaction.atomic
def reorder_stops(plan: DayPlan, stop_ids: list) -> None:
    stops = {stop.id: stop for stop in plan.stops.all()}
    if set(stop_ids) != set(stops) or len(stop_ids) != len(stops):
        raise ValueError("stop_ids must contain every stop in the plan exactly once.")
    for index, stop_id in enumerate(stop_ids):
        stop = stops[stop_id]
        if stop.position != index:
            stop.position = index
            stop.save(update_fields=["position"])
    rebuild_legs(plan)


def get_or_create_today(profile) -> DayPlan:
    plan, _ = DayPlan.objects.get_or_create(
        owner=profile, date=timezone.localdate(), defaults={"title": "Today", "budget": profile.default_budget}
    )
    return plan
