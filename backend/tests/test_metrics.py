import json
import uuid
from datetime import UTC, datetime, time, timedelta

import pytest
from django.utils import timezone
from rest_framework.throttling import ScopedRateThrottle

from plandit.core.models import ActivityDay, ActivityEvent, Profile
from plandit.core.views import MetricsView
from plandit.plans.models import GroupAnswer, GroupRequest
from plandit.shares.models import ShareAnswer, SharedPlan
from plandit.waitlist.models import WaitlistSignup

pytestmark = pytest.mark.django_db

KEY = "test-metrics-key-0123456789"


@pytest.fixture
def metrics_key(settings):
    settings.METRICS_API_KEY = KEY
    return KEY


def get(client, *, key=KEY, header=True, **params):
    if header:
        return client.get("/api/metrics/", params, HTTP_X_METRICS_KEY=key)
    return client.get("/api/metrics/", {**params, "key": key})


def make_profile(*, email="", is_anonymous=False, signed_up_at=None, activated_at=None, **fields):
    return Profile.objects.create(
        id=uuid.uuid4(),
        email=email,
        is_anonymous=is_anonymous,
        signed_up_at=signed_up_at,
        activated_at=activated_at,
        **fields,
    )


def test_metrics_is_off_when_no_key_is_configured(api_client, settings):
    settings.METRICS_API_KEY = ""
    assert get(api_client).status_code == 404
    assert get(api_client, key="").status_code == 404


def test_missing_key_is_403(api_client, metrics_key):
    assert api_client.get("/api/metrics/").status_code == 403


def test_wrong_key_is_403(api_client, metrics_key):
    assert get(api_client, key="nope").status_code == 403
    assert get(api_client, key="nope", header=False).status_code == 403
    assert get(api_client, key=KEY + "x").status_code == 403


def test_valid_key_in_header_or_query(api_client, metrics_key):
    assert get(api_client).status_code == 200
    assert get(api_client, header=False).status_code == 200


def test_no_jwt_needed_and_bearer_is_ignored(api_client, metrics_key):
    api_client.credentials(HTTP_AUTHORIZATION="Bearer not-a-jwt")
    assert get(api_client).status_code == 200
    assert MetricsView.authentication_classes == []


def test_metrics_throttle_scope(settings):
    assert MetricsView.throttle_scope == "metrics"
    assert MetricsView.throttle_classes == [ScopedRateThrottle]
    assert "metrics" in settings.REST_FRAMEWORK["DEFAULT_THROTTLE_RATES"]


@pytest.mark.parametrize("days", ["0", "366", "-1", "abc", "1.5", ""])
def test_days_out_of_bounds_is_400(api_client, metrics_key, days):
    response = get(api_client, days=days)
    assert response.status_code == 400
    assert "days" in response.json()


@pytest.mark.parametrize("days", [1, 7, 365])
def test_days_bounds_and_daily_length(api_client, metrics_key, days):
    body = get(api_client, days=days).json()
    assert len(body["daily"]) == days
    today = timezone.localdate()
    assert body["daily"][-1]["date"] == today.isoformat()
    assert body["daily"][0]["date"] == (today - timedelta(days=days - 1)).isoformat()
    dates = [row["date"] for row in body["daily"]]
    assert dates == sorted(dates)


def test_default_is_30_days_and_zero_filled(api_client, metrics_key):
    body = get(api_client).json()
    assert len(body["daily"]) == 30
    for row in body["daily"]:
        assert row == {
            "date": row["date"],
            "signups": 0,
            "new_real_users": 0,
            "active_users": 0,
            "plans_built": 0,
            "places_saved": 0,
            "links_saved": 0,
        }
    assert body["product"] == "Plandit"
    assert body["timezone"] == "America/New_York"
    assert body["generated_at"].endswith("Z")
    assert set(body["definitions"]) == {"signup", "real_user", "active_user"}
    assert body["totals"] == {
        "signups": 0,
        "real_users": 0,
        "activation_rate": 0.0,
        "active_users_today": 0,
        "active_users_7d": 0,
        "active_users_30d": 0,
        "plans_built": 0,
        "places_saved": 0,
        "links_saved": 0,
        "waitlist_signups": 0,
        "anonymous_sessions": 0,
        "links_with_answers": 0,
        "answers_per_link": 0.0,
        "plan_requests": 0,
        "plan_requests_built": 0,
    }


def test_totals_and_daily_counts(api_client, metrics_key):
    now = timezone.now()
    today = timezone.localdate(now)
    yesterday_ts = now - timedelta(days=1)
    ten_days_ago_ts = now - timedelta(days=10)

    # Three signups: one real user activated yesterday, one activated 10 days ago, one not yet.
    a = make_profile(email="a@columbia.edu", signed_up_at=ten_days_ago_ts, activated_at=yesterday_ts)
    b = make_profile(email="b@nyu.edu", signed_up_at=yesterday_ts, activated_at=ten_days_ago_ts)
    c = make_profile(email="c@columbia.edu", signed_up_at=now)
    # Two anonymous sessions, one of them very active; never counted.
    anon = make_profile(is_anonymous=True)
    make_profile(is_anonymous=True)

    ActivityDay.objects.create(profile=a, date=today)
    ActivityDay.objects.create(profile=b, date=today)
    ActivityDay.objects.create(profile=b, date=today - timedelta(days=1))
    ActivityDay.objects.create(profile=c, date=today - timedelta(days=5))
    ActivityDay.objects.create(profile=c, date=today - timedelta(days=20))
    ActivityDay.objects.create(profile=anon, date=today)
    ActivityDay.objects.create(profile=anon, date=today - timedelta(days=1))

    ActivityEvent.objects.create(profile=a, name="plan_built", occurred_at=yesterday_ts)
    ActivityEvent.objects.create(profile=a, name="plan_built", occurred_at=now)
    ActivityEvent.objects.create(profile=b, name="place_saved", occurred_at=now)
    ActivityEvent.objects.create(profile=b, name="link_saved", occurred_at=ten_days_ago_ts)
    ActivityEvent.objects.create(profile=b, name="link_saved", occurred_at=now - timedelta(days=40))
    ActivityEvent.objects.create(profile=anon, name="plan_built", occurred_at=now)
    ActivityEvent.objects.create(profile=anon, name="link_saved", occurred_at=now)

    WaitlistSignup.objects.create(email="w1@example.com")
    WaitlistSignup.objects.create(email="w2@example.com")

    body = get(api_client, days=30).json()
    assert body["totals"] == {
        "signups": 3,
        "real_users": 2,
        "activation_rate": 0.667,
        "active_users_today": 2,
        "active_users_7d": 3,
        "active_users_30d": 3,
        "plans_built": 2,
        "places_saved": 1,
        "links_saved": 2,
        "waitlist_signups": 2,
        "anonymous_sessions": 2,
        "links_with_answers": 0,
        "answers_per_link": 0.0,
        "plan_requests": 0,
        "plan_requests_built": 0,
    }

    by_date = {row["date"]: row for row in body["daily"]}
    day = lambda ts: timezone.localdate(ts).isoformat()  # noqa: E731
    assert by_date[day(now)]["signups"] == 1
    assert by_date[day(yesterday_ts)]["signups"] == 1
    assert by_date[day(ten_days_ago_ts)]["signups"] == 1
    assert by_date[day(yesterday_ts)]["new_real_users"] == 1
    assert by_date[day(ten_days_ago_ts)]["new_real_users"] == 1
    assert by_date[day(now)]["active_users"] == 2
    assert by_date[day(yesterday_ts)]["active_users"] == 1
    assert by_date[(today - timedelta(days=5)).isoformat()]["active_users"] == 1
    assert by_date[day(now)]["plans_built"] == 1
    assert by_date[day(yesterday_ts)]["plans_built"] == 1
    assert by_date[day(now)]["places_saved"] == 1
    assert by_date[day(ten_days_ago_ts)]["links_saved"] == 1
    assert sum(row["signups"] for row in body["daily"]) == 3
    assert sum(row["links_saved"] for row in body["daily"]) == 1  # the 40-day-old one is outside the window
    assert sum(row["plans_built"] for row in body["daily"]) == 2  # the anonymous plan is excluded


def test_signup_without_signed_up_at_is_not_counted(api_client, metrics_key):
    # Pre-migration shape that the backfill fixes; the metrics never guess.
    make_profile(email="legacy@columbia.edu", signed_up_at=None)
    assert get(api_client).json()["totals"]["signups"] == 0


def test_active_window_edges(api_client, metrics_key):
    today = timezone.localdate()
    p = make_profile(email="edge@columbia.edu", signed_up_at=timezone.now())
    ActivityDay.objects.create(profile=p, date=today - timedelta(days=6))
    q = make_profile(email="edge2@columbia.edu", signed_up_at=timezone.now())
    ActivityDay.objects.create(profile=q, date=today - timedelta(days=7))
    r = make_profile(email="edge3@columbia.edu", signed_up_at=timezone.now())
    ActivityDay.objects.create(profile=r, date=today - timedelta(days=29))
    s = make_profile(email="edge4@columbia.edu", signed_up_at=timezone.now())
    ActivityDay.objects.create(profile=s, date=today - timedelta(days=30))
    totals = get(api_client, days=1).json()["totals"]
    assert totals["active_users_today"] == 0
    assert totals["active_users_7d"] == 1
    assert totals["active_users_30d"] == 3


def test_payload_never_contains_emails_or_ids(api_client, metrics_key):
    p = make_profile(
        email="secret.person@columbia.edu",
        name="Secret Person",
        signed_up_at=timezone.now(),
        activated_at=timezone.now(),
    )
    ActivityDay.objects.create(profile=p, date=timezone.localdate())
    ActivityEvent.objects.create(profile=p, name="plan_built", occurred_at=timezone.now())
    WaitlistSignup.objects.create(email="waiting@example.com")
    text = json.dumps(get(api_client).json())
    assert "@" not in text
    assert "secret" not in text.lower()
    assert str(p.id) not in text
    assert "email" not in text.lower().replace("email or apple", "")  # only the definition mentions email sign-in


def test_late_evening_local_time_lands_in_yesterdays_bucket(api_client, metrics_key):
    # 23:30 America/New_York yesterday is already "today" in UTC; the daily series is local.
    tz = timezone.get_current_timezone()
    today = timezone.localdate()
    yesterday = today - timedelta(days=1)
    late = timezone.make_aware(datetime.combine(yesterday, time(23, 30)), tz)
    assert late.astimezone(UTC).date() == today  # the boundary this test is about

    p = make_profile(email="night@columbia.edu", signed_up_at=late, activated_at=late)
    ActivityEvent.objects.create(profile=p, name="plan_built", occurred_at=late)
    ActivityEvent.objects.create(profile=p, name="link_saved", occurred_at=late)

    body = get(api_client, days=3).json()
    by_date = {row["date"]: row for row in body["daily"]}
    assert by_date[yesterday.isoformat()] == {
        "date": yesterday.isoformat(),
        "signups": 1,
        "new_real_users": 1,
        "active_users": 0,
        "plans_built": 1,
        "places_saved": 0,
        "links_saved": 1,
    }
    assert by_date[today.isoformat()]["signups"] == 0
    assert by_date[today.isoformat()]["plans_built"] == 0
    assert by_date[today.isoformat()]["links_saved"] == 0
    assert body["totals"]["signups"] == 1
    assert body["totals"]["plans_built"] == 1


def add_answers(link, names):
    for name in names:
        ShareAnswer.objects.create(
            shared_plan=link, responder=uuid.uuid4().hex * 2, name=name, status="in", plan_date=timezone.localdate()
        )


def test_answer_counts_without_names(api_client, metrics_key):
    """Group plans: links with at least one friend's answer, and answers per such link."""
    owner = make_profile(email="o@columbia.edu", signed_up_at=timezone.now())
    links = [SharedPlan.objects.create(owner=owner, plan_id=uuid.uuid4(), data={}) for _ in range(3)]
    add_answers(links[0], ["Quentinia", "Zebulon", "Marisol"])
    add_answers(links[1], ["Leopoldine"])
    anonymous_link = SharedPlan.objects.create(owner=make_profile(is_anonymous=True), plan_id=uuid.uuid4(), data={})
    add_answers(anonymous_link, ["Bartholomew"])

    body = get(api_client).json()
    assert body["totals"]["links_with_answers"] == 2
    assert body["totals"]["answers_per_link"] == 2.0
    text = json.dumps(body)
    for name in ("Quentinia", "Zebulon", "Marisol", "Leopoldine", "Bartholomew"):
        assert name not in text


def make_plan_request(owner, status="open") -> GroupRequest:
    return GroupRequest.objects.create(
        owner=owner,
        places=[],
        day=timezone.localdate() + timedelta(days=1),
        window_start=time(12),
        window_end=time(20),
        time_zone="America/New_York",
        answers_by=timezone.now() + timedelta(hours=2),
        status=status,
    )


def test_friends_input_link_counts_without_names(api_client, metrics_key):
    """Group plans, mode 2: how many friends' input links there are and how many got built."""
    owner = make_profile(email="o@columbia.edu", signed_up_at=timezone.now())
    make_plan_request(owner)
    make_plan_request(owner, status="closed")
    built = make_plan_request(owner, status="built")
    make_plan_request(owner, status="built")
    make_plan_request(make_profile(is_anonymous=True), status="built")
    GroupAnswer.objects.create(
        request=built,
        responder=uuid.uuid4().hex * 2,
        name="Quentinia",
        budget=137,
        free_from=time(13),
        free_until=time(18),
    )

    body = get(api_client).json()
    assert (body["totals"]["plan_requests"], body["totals"]["plan_requests_built"]) == (4, 2)
    text = json.dumps(body)
    assert "Quentinia" not in text and "137" not in text
