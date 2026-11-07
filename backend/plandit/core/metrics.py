"""
Aggregate usage metrics for GET /api/metrics/ (the professor's endpoint).

Everything is counted in the database, grouped by local day in the project time zone. The
payload holds counts only: no ids, emails or names. Anonymous profiles (old TestFlight builds)
are excluded from every number except `anonymous_sessions`.
"""

from datetime import UTC, date, datetime, time, timedelta

from django.conf import settings
from django.db.models import Count
from django.db.models.functions import TruncDate
from django.utils import timezone

from plandit.waitlist.models import WaitlistSignup

from .models import ActivityDay, ActivityEvent, ActivityEventName, Profile

MIN_DAYS = 1
MAX_DAYS = 365
DEFAULT_DAYS = 30

DEFINITIONS = {
    "signup": "An account created with email or Apple that has opened the app at least once.",
    "real_user": "A signup who built a plan with at least one stop (Plandit's core action).",
    "active_user": "A signup who used the app that day.",
}

EVENT_TOTAL_KEYS = {
    ActivityEventName.PLAN_BUILT: "plans_built",
    ActivityEventName.PLACE_SAVED: "places_saved",
    ActivityEventName.LINK_SAVED: "links_saved",
}


def iso_utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _local_midnight(day: date):
    return timezone.make_aware(datetime.combine(day, time.min), timezone.get_current_timezone())


def _active_users_between(first: date, last: date) -> int:
    rows = ActivityDay.objects.filter(date__gte=first, date__lte=last, profile__is_anonymous=False)
    return rows.aggregate(n=Count("profile", distinct=True))["n"]


def compute_metrics(days: int = DEFAULT_DAYS) -> dict:
    now = timezone.now()
    today = timezone.localdate(now)
    tz = timezone.get_current_timezone()
    first_day = today - timedelta(days=days - 1)
    window_start = _local_midnight(first_day)

    signups = Profile.objects.filter(is_anonymous=False, signed_up_at__isnull=False)
    signup_total = signups.count()
    real_user_total = signups.filter(activated_at__isnull=False).count()
    events = ActivityEvent.objects.filter(profile__is_anonymous=False)

    event_totals = dict.fromkeys(EVENT_TOTAL_KEYS.values(), 0)
    for row in events.values("name").annotate(n=Count("id")):
        key = EVENT_TOTAL_KEYS.get(row["name"])
        if key:
            event_totals[key] = row["n"]

    totals = {
        "signups": signup_total,
        "real_users": real_user_total,
        "activation_rate": round(real_user_total / signup_total, 3) if signup_total else 0.0,
        "active_users_today": _active_users_between(today, today),
        "active_users_7d": _active_users_between(today - timedelta(days=6), today),
        "active_users_30d": _active_users_between(today - timedelta(days=29), today),
        **event_totals,
        "waitlist_signups": WaitlistSignup.objects.count(),
        "anonymous_sessions": Profile.objects.filter(is_anonymous=True).count(),
    }

    daily = {
        first_day + timedelta(days=offset): {
            "date": (first_day + timedelta(days=offset)).isoformat(),
            "signups": 0,
            "new_real_users": 0,
            "active_users": 0,
            "plans_built": 0,
            "places_saved": 0,
            "links_saved": 0,
        }
        for offset in range(days)
    }

    def fill(rows, key, day_key="day"):
        for row in rows:
            bucket = daily.get(row[day_key])
            if bucket is not None:
                bucket[key] = row["n"]

    fill(
        signups.filter(signed_up_at__gte=window_start)
        .annotate(day=TruncDate("signed_up_at", tzinfo=tz))
        .values("day")
        .annotate(n=Count("id")),
        "signups",
    )
    fill(
        signups.filter(activated_at__gte=window_start)
        .annotate(day=TruncDate("activated_at", tzinfo=tz))
        .values("day")
        .annotate(n=Count("id")),
        "new_real_users",
    )
    fill(
        ActivityDay.objects.filter(date__gte=first_day, profile__is_anonymous=False)
        .values("date")
        .annotate(n=Count("id")),
        "active_users",
        day_key="date",
    )
    event_rows = (
        events.filter(occurred_at__gte=window_start)
        .annotate(day=TruncDate("occurred_at", tzinfo=tz))
        .values("day", "name")
        .annotate(n=Count("id"))
    )
    for row in event_rows:
        bucket = daily.get(row["day"])
        key = EVENT_TOTAL_KEYS.get(row["name"])
        if bucket is not None and key:
            bucket[key] = row["n"]

    return {
        "product": "Plandit",
        "generated_at": iso_utc(now),
        "timezone": settings.TIME_ZONE,
        "definitions": DEFINITIONS,
        "totals": totals,
        "daily": [daily[day] for day in sorted(daily)],
    }
