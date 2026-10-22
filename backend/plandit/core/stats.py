"""Profile stats, computed from past plans. Cheap enough to do per request for now."""

from datetime import date, timedelta
from decimal import Decimal

from django.utils import timezone

from plandit.plans.models import DayPlan, StopStatus, TravelMode


def _week(day: date) -> date:
    return day - timedelta(days=day.weekday())


def compute_stats(profile) -> dict:
    today = timezone.localdate()
    past_plans = (
        DayPlan.objects.filter(owner=profile, date__lt=today).prefetch_related("stops__place", "legs").order_by("date")
    )
    completed = [plan for plan in past_plans if any(s.status == StopStatus.DONE for s in plan.stops.all())]

    neighborhoods = {
        stop.place.neighborhood
        for plan in completed
        for stop in plan.stops.all()
        if stop.status == StopStatus.DONE and stop.place.neighborhood
    }
    miles_walked = sum(leg.miles for plan in completed for leg in plan.legs.all() if leg.mode == TravelMode.WALK)
    costs = [plan.total_cost for plan in completed]
    average_spend = (sum(costs, Decimal(0)) / len(costs)) if costs else Decimal(0)
    under_budget = sum(1 for plan in completed if plan.total_cost <= plan.budget)

    weeks = {_week(plan.date) for plan in completed}
    cursor = _week(today)
    if cursor not in weeks:
        cursor -= timedelta(weeks=1)
    streak = 0
    while cursor in weeks:
        streak += 1
        cursor -= timedelta(weeks=1)

    return {
        "plans_completed": len(completed),
        "neighborhoods_visited": len(neighborhoods),
        "miles_walked": round(miles_walked, 1),
        "average_spend": round(float(average_spend), 2),
        "plans_under_budget": under_budget,
        "streak_weeks": streak,
    }
