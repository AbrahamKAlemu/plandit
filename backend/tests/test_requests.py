"""Friends' input links (group plans, mode 2, slice G2a; brief GI-1 to GI-8, GS-1 to GS-5).

The organizer's app creates a request (places, a day, a time range and a deadline) and sends its
/g/ link. Friends answer on the page without an account; the organizer reads the answers through
the owner API and builds the plan on the phone, then shares it with the request's slug."""

import copy
import hashlib
import uuid
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from django.db import IntegrityError, connection, transaction
from django.utils import timezone

from plandit.core import retention
from plandit.plans.models import GroupAnswer, GroupRequest
from tests.test_answers import empty_throttle_cache  # noqa: F401

pytestmark = pytest.mark.django_db

TZ = "America/New_York"
# The app sends Swift UUIDs, which are upper case; they come back exactly as sent.
MET = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
TACOS = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
HIGH_LINE = "11111111-2222-4333-8444-555555555555"
PIZZA = "33333333-4444-4555-8666-777777777777"
PLACES = [
    {"id": MET, "name": "The Met", "neighborhood": "Upper East Side", "kind": "Culture", "costText": "$30"},
    {"id": TACOS, "name": "Los Tacos No. 1", "neighborhood": "Chelsea", "kind": "Food", "costText": "$6"},
    {"id": HIGH_LINE, "name": "The High Line", "neighborhood": "Chelsea", "kind": "Outdoors", "costText": "Free"},
    {"id": PIZZA, "name": "Prince Street Pizza", "neighborhood": "Nolita", "kind": "Food", "costText": "$6"},
]


def local_today(zone=TZ) -> date:
    return datetime.now(ZoneInfo(zone)).date()


def make_request(owner, **fields) -> GroupRequest:
    """A request straight in the database: tomorrow, 12 to 8 PM, answers in 2 hours."""
    values = {
        "owner": owner,
        "places": copy.deepcopy(PLACES),
        "day": local_today() + timedelta(days=1),
        "window_start": time(12),
        "window_end": time(20),
        "time_zone": TZ,
        "answers_by": timezone.now() + timedelta(hours=2),
    }
    values.update(fields)
    return GroupRequest.objects.create(**values)


def add_answer(group, name="Seed", **fields) -> GroupAnswer:
    values = {
        "request": group,
        "responder": hashlib.sha256(f"{name}-{uuid.uuid4()}".encode()).hexdigest(),
        "name": name,
        "budget": 40,
        "free_from": time(13),
        "free_until": time(18),
        "stars": [TACOS],
    }
    values.update(fields)
    return GroupAnswer.objects.create(**values)


# --- GS-1: row level security on both new tables -------------------------------------------


@pytest.mark.parametrize("table", ["plans_grouprequest", "plans_groupanswer"])
def test_the_new_tables_have_row_level_security(table):
    with connection.cursor() as cursor:
        cursor.execute("select relrowsecurity from pg_class where relname = %s", [table])
        assert cursor.fetchone() == (True,)


# --- The database refuses answers the form would refuse ------------------------------------


def test_the_database_refuses_a_budget_over_150(profile):
    group = make_request(profile)
    with pytest.raises(IntegrityError), transaction.atomic():
        add_answer(group, budget=151)


@pytest.mark.parametrize("until", [time(13), time(12)])
def test_the_database_refuses_a_free_time_that_ends_before_it_starts(profile, until):
    group = make_request(profile)
    with pytest.raises(IntegrityError), transaction.atomic():
        add_answer(group, free_from=time(13), free_until=until)


def test_one_answer_per_browser_per_request(profile):
    group = make_request(profile)
    first = add_answer(group)
    with pytest.raises(IntegrityError), transaction.atomic():
        add_answer(group, responder=first.responder)
    add_answer(make_request(profile), responder=first.responder)  # another link: another answer


# --- GS-5: deleted 30 days after the day, with the request, or with the account ------------


def test_requests_are_registered_for_expiry_30_days_after_their_day():
    rules = [rule for rule in retention.RULES if rule.model is GroupRequest]
    assert [(rule.date_field, rule.days) for rule in rules] == [("day", 30)]


def test_purge_expired_deletes_expired_requests_with_their_answers_and_nothing_else(profile):
    now = datetime(2026, 12, 31, 12, tzinfo=UTC)
    for label, days in {"Old": 31, "Boundary": 30, "Recent": 29, "Upcoming": -3}.items():
        group = make_request(profile, day=date(2026, 12, 31) - timedelta(days=days))
        add_answer(group, name=label)

    deleted = retention.purge_expired(now)
    assert deleted["plans.GroupRequest.day"] == 4  # 2 requests and their 2 answers
    assert sorted(GroupAnswer.objects.values_list("name", flat=True)) == ["Recent", "Upcoming"]
    assert GroupRequest.objects.count() == 2


def test_deleting_a_request_deletes_its_answers(profile):
    group = make_request(profile)
    add_answer(group)
    other = add_answer(make_request(profile))
    group.delete()
    assert list(GroupAnswer.objects.all()) == [other]


def test_deleting_the_account_deletes_its_requests_and_their_answers(auth_client, profile):
    add_answer(make_request(profile))
    assert auth_client.delete("/api/me/").status_code == 204
    assert not GroupRequest.objects.exists()
    assert not GroupAnswer.objects.exists()
