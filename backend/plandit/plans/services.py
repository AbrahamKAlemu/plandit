"""Plan mutations that keep stops and legs consistent. Travel legs are estimated the same way
the iOS app does it until a real routing/transit service is wired in."""

from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal

from django.db import transaction
from django.utils import timezone

from . import planner
from .models import DayPlan, PlanStop, StopStatus, TravelLeg
from .planner import SUBWAY_FARE, WALK_LIMIT_MILES, haversine_miles  # noqa: F401 (re-exported)


def estimate_leg(plan: DayPlan, a: PlanStop, b: PlanStop, *, walk_only: bool = False) -> TravelLeg:
    """Rough leg: walk under ~1.2 mi, otherwise subway (or always walk, for walk-only)."""
    travel = planner.estimate_travel(a.place, b.place, walk_only=walk_only)
    return TravelLeg(
        plan=plan,
        from_stop=a,
        to_stop=b,
        mode=travel.mode,
        minutes=travel.minutes,
        miles=travel.miles,
        cost=travel.cost,
        detail=travel.detail,
    )


@transaction.atomic
def rebuild_legs(plan: DayPlan) -> None:
    """Keeps existing legs between consecutive stops and estimates any new pairs."""
    stops = list(plan.stops.select_related("place").order_by("position", "start"))
    existing = {(leg.from_stop_id, leg.to_stop_id): leg for leg in plan.legs.all()}
    walk_only = planner.walk_only(plan.owner.travel_modes)
    keep: list = []
    for a, b in zip(stops, stops[1:], strict=False):
        leg = existing.get((a.id, b.id))
        if leg is None:
            leg = estimate_leg(plan, a, b, walk_only=walk_only)
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


class PlanMode:
    ADD = "add"  # keep what's done or underway; re-order the rest together with the new picks
    REPLACE = "replace"  # throw out the plan and plan only the picks


@dataclass
class BuildResult:
    plan: DayPlan
    outcome: planner.Outcome


def locked_stops(plan: DayPlan) -> list[PlanStop]:
    """Stops already done or underway. Re-planning never moves these."""
    stops = list(plan.stops.select_related("place").order_by("position", "start"))
    last = max((i for i, stop in enumerate(stops) if stop.status != StopStatus.UPCOMING), default=-1)
    return stops[: last + 1]


def plan_title(stops) -> str:
    """ "Morningside Heights to West Village", or "A day in Chelsea" when it stays in one neighborhood."""
    if not stops:
        return "Today"
    first, last = stops[0].place.neighborhood, stops[-1].place.neighborhood
    if not first or not last:
        return "Today"
    return f"A day in {first}" if first == last else f"{first} to {last}"


@transaction.atomic
def build_plan(
    plan: DayPlan, *, saved_posts, start, budget: Decimal, mode: str = PlanMode.ADD, end=None
) -> BuildResult:
    """Plans the picked saved posts into `plan`. Same rules as the iOS planner (see planner.py)."""
    walk_only = planner.walk_only(plan.owner.travel_modes)
    start = timezone.localtime(start)
    picked = [
        planner.Candidate(
            place=post.place,
            cost=post.estimated_cost or Decimal(0),
            key=post,
            note=f"Added from your saved {post.get_platform_display()} post.",
        )
        for post in saved_posts
    ]

    locked: list[PlanStop] = []
    already_spent = Decimal(0)
    candidates = picked
    if mode == PlanMode.ADD:
        locked = locked_stops(plan)
        locked_ids = {stop.id for stop in locked}
        upcoming = [stop for stop in plan.stops.select_related("place") if stop.id not in locked_ids]
        upcoming.sort(key=lambda stop: (stop.position, stop.start))
        in_plan = {stop.source_post_id for stop in plan.stops.all() if stop.source_post_id}
        candidates = [
            planner.Candidate(
                place=s.place, cost=s.estimated_cost, duration_minutes=s.duration_minutes, key=s, note=s.note
            )
            for s in upcoming
        ] + [c for c in picked if c.key.id not in in_plan]
        already_spent = sum((s.estimated_cost for s in locked), Decimal(0)) + sum(
            (leg.cost for leg in plan.legs.all() if leg.from_stop_id in locked_ids and leg.to_stop_id in locked_ids),
            Decimal(0),
        )

    anchor = planner.Anchor(locked[-1].place, timezone.localtime(locked[-1].end)) if locked else None
    day_end = None
    if end is not None:
        # "Until 1 AM" after a 10 PM start means tomorrow; "until 2 PM" after 3 PM just means nothing fits.
        day_end = timezone.localtime(end)
        if day_end <= (anchor.end if anchor else start) and day_end.hour < 6:
            day_end += timedelta(days=1)
    outcome = planner.plan_day(
        candidates,
        start=start,
        budget=Decimal(budget),
        walk_only=walk_only,
        anchor=anchor,
        already_spent=already_spent,
        day_end=day_end,
    )

    # Stops: keep locked ones, update re-planned ones in place, create new ones, delete the rest.
    locked_ids = {stop.id for stop in locked}
    replanned_ids = {p.candidate.key.id for p in outcome.stops if isinstance(p.candidate.key, PlanStop)}
    plan.stops.exclude(id__in=locked_ids | replanned_ids).delete()  # cascades their legs
    plan.legs.exclude(from_stop_id__in=locked_ids, to_stop_id__in=locked_ids).delete()

    ordered: list[PlanStop] = list(locked)
    for planned in outcome.stops:
        key = planned.candidate.key
        if isinstance(key, PlanStop):
            stop = key
            stop.start, stop.duration_minutes, stop.note = planned.start, planned.duration_minutes, planned.note
        else:
            stop = PlanStop(
                plan=plan,
                place=planned.candidate.place,
                start=planned.start,
                duration_minutes=planned.duration_minutes,
                estimated_cost=planned.candidate.cost,
                note=planned.note,
                source_post=key,
            )
        ordered.append(stop)
    for index, stop in enumerate(ordered):
        stop.position = index
        stop.save()

    # Legs into each planned stop come straight from the planner (the first one starts at the anchor).
    for index, travel in enumerate(outcome.legs):
        to_index = len(locked) + (index if outcome.leg_from_anchor else index + 1)
        TravelLeg.objects.create(
            plan=plan,
            from_stop=ordered[to_index - 1],
            to_stop=ordered[to_index],
            mode=travel.mode,
            minutes=travel.minutes,
            miles=travel.miles,
            cost=travel.cost,
            detail=travel.detail,
        )

    plan.budget = Decimal(budget)
    if mode == PlanMode.REPLACE or not locked:
        plan.title = plan_title(ordered)
    plan.save(update_fields=["budget", "title", "updated_at"])
    return BuildResult(plan, outcome)
