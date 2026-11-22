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


# --- GI-1: the organizer creates a request --------------------------------------------------


def request_payload(**overrides) -> dict:
    """What the app sends: tomorrow, 12 to 8 PM in New York, answers in 2 hours."""
    payload = {
        "places": copy.deepcopy(PLACES),
        "day": (local_today() + timedelta(days=1)).isoformat(),
        "windowStart": "12:00",
        "windowEnd": "20:00",
        "timeZone": TZ,
        "answersBy": (timezone.now() + timedelta(hours=2)).isoformat(),
    }
    payload.update(overrides)
    return payload


def create(client, payload):
    return client.post("/api/plan-requests/", payload, format="json")


def utc_text(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


REQUEST_KEYS = {
    "slug",
    "url",
    "status",
    "places",
    "day",
    "windowStart",
    "windowEnd",
    "timeZone",
    "answersBy",
    "planSlug",
    "createdAt",
    "answers",
}


def test_creating_a_request_returns_its_link_and_what_was_asked(auth_client, user_id):
    payload = request_payload()
    response = create(auth_client, payload)

    assert response.status_code == 201
    body = response.json()
    assert set(body) == REQUEST_KEYS
    assert len(body["slug"]) == 10
    assert body["url"] == f"http://testserver/g/{body['slug']}"
    assert body["status"] == "open"
    assert body["places"] == PLACES  # ids exactly as sent
    assert (body["day"], body["windowStart"], body["windowEnd"], body["timeZone"]) == (
        payload["day"],
        "12:00",
        "20:00",
        TZ,
    )
    assert body["answersBy"] == utc_text(datetime.fromisoformat(payload["answersBy"]))
    assert body["planSlug"] is None
    assert body["answers"] == []

    stored = GroupRequest.objects.get()
    assert stored.owner_id == user_id
    assert stored.slug == body["slug"]
    assert (stored.window_start, stored.window_end) == (time(12), time(20))
    assert stored.answers_by == datetime.fromisoformat(payload["answersBy"])
    assert stored.status == "open"


def test_request_links_use_the_site_address_once_configured(auth_client, settings):
    settings.SHARE_BASE_URL = "https://plandit.app"
    body = create(auth_client, request_payload()).json()
    assert body["url"] == f"https://plandit.app/g/{body['slug']}"


def test_creating_a_request_needs_an_account(api_client):
    assert create(api_client, request_payload()).status_code in (401, 403)
    assert not GroupRequest.objects.exists()


def ten_places():
    return [{"id": str(uuid.uuid4()).upper(), "name": f"Place {n}", "costText": "Free"} for n in range(10)]


def at(day: str, hour: int, minute: int = 0, zone: str = TZ) -> str:
    return datetime.combine(date.fromisoformat(day), time(hour, minute), tzinfo=ZoneInfo(zone)).isoformat()


BAD_REQUESTS = {
    "one place": ("places", lambda p: p.update(places=PLACES[:1])),
    "eleven places": ("places", lambda p: p.update(places=ten_places() + PLACES[:1])),
    "no places": ("places", lambda p: p.update(places=[])),
    "places missing": ("places", lambda p: p.pop("places")),
    "the same place twice, in any case": (
        "places",
        lambda p: p.update(places=[PLACES[0], {**PLACES[1], "id": MET.lower()}]),
    ),
    "a place id that isn't a UUID": ("places", lambda p: p["places"][0].update(id="the-met")),
    "a place without a name": ("places", lambda p: p["places"][0].pop("name")),
    "a place name over 120 characters": ("places", lambda p: p["places"][0].update(name="x" * 121)),
    "a cost text over 40 characters": ("places", lambda p: p["places"][0].update(costText="$" * 41)),
    "yesterday": ("day", lambda p: p.update(day=(local_today() - timedelta(days=1)).isoformat())),
    "15 days ahead": ("day", lambda p: p.update(day=(local_today() + timedelta(days=15)).isoformat())),
    "a day not written YYYY-MM-DD": ("day", lambda p: p.update(day="11/22/2026")),
    "a day with a time": ("day", lambda p: p.update(day=p["day"] + "T12:00:00")),
    "a range under an hour": ("windowEnd", lambda p: p.update(windowEnd="12:59")),
    "a range that ends before it starts": ("windowEnd", lambda p: p.update(windowStart="20:00", windowEnd="12:00")),
    "a time with seconds": ("windowStart", lambda p: p.update(windowStart="12:00:00")),
    "a time that isn't one": ("windowStart", lambda p: p.update(windowStart="noon")),
    "hour 24": ("windowEnd", lambda p: p.update(windowEnd="24:00")),
    "an unknown time zone": ("timeZone", lambda p: p.update(timeZone="Mars/Olympus_Mons")),
    "a path for a time zone": ("timeZone", lambda p: p.update(timeZone="../../etc/passwd")),
    "no time zone": ("timeZone", lambda p: p.update(timeZone="")),
    "a deadline that has passed": (
        "answersBy",
        lambda p: p.update(answersBy=(timezone.now() - timedelta(minutes=1)).isoformat()),
    ),
    "a deadline after the range ends": ("answersBy", lambda p: p.update(answersBy=at(p["day"], 20, 1))),
    "a deadline without a UTC offset": ("answersBy", lambda p: p.update(answersBy=p["day"] + "T10:00:00")),
    "a deadline that isn't a moment": ("answersBy", lambda p: p.update(answersBy="Friday 9 PM")),
}


@pytest.mark.parametrize(("field", "change"), BAD_REQUESTS.values(), ids=BAD_REQUESTS.keys())
def test_bad_requests_are_refused(auth_client, field, change):
    payload = request_payload()
    change(payload)
    response = create(auth_client, payload)
    assert response.status_code == 400
    assert set(response.json()) == {field}
    assert not GroupRequest.objects.exists()


GOOD_EDGES = {
    "exactly 2 places": lambda p: p.update(places=PLACES[:2]),
    "exactly 10 places": lambda p: p.update(places=ten_places()),
    "14 days ahead": lambda p: p.update(day=(local_today() + timedelta(days=14)).isoformat()),
    "a range of exactly 1 hour": lambda p: p.update(windowStart="12:00", windowEnd="13:00"),
    "a deadline at the end of the range": lambda p: p.update(answersBy=at(p["day"], 20)),
    "a deadline in UTC with a Z": lambda p: p.update(answersBy=utc_text(timezone.now() + timedelta(hours=2))),
    "lower-case ids": lambda p: p.update(places=[{**place, "id": place["id"].lower()} for place in PLACES]),
    "a place with only an id and a name": lambda p: p.update(places=[{"id": MET, "name": "The Met"}, PLACES[1]]),
    "UTC": lambda p: p.update(timeZone="UTC", day=(local_today("UTC") + timedelta(days=1)).isoformat()),
}


@pytest.mark.parametrize("change", GOOD_EDGES.values(), ids=GOOD_EDGES.keys())
def test_requests_at_the_edges_are_accepted(auth_client, change):
    payload = request_payload()
    change(payload)
    response = create(auth_client, payload)
    assert response.status_code == 201, response.json()
    assert response.json()["places"] == [
        {"neighborhood": "", "kind": "", "costText": "", **place} for place in payload["places"]
    ]


@pytest.fixture
def today_payload():
    """Brief GI-1: today to 14 days out. Skipped in the last minutes of the day, when no deadline
    is left before the range ends."""
    if datetime.now(ZoneInfo(TZ)).time() > time(23, 55):
        pytest.skip("too close to midnight in New York")
    return request_payload(
        day=local_today().isoformat(),
        windowStart="00:00",
        windowEnd="23:59",
        answersBy=(timezone.now() + timedelta(minutes=2)).isoformat(),
    )


def test_a_request_for_later_today_is_accepted(auth_client, today_payload):
    assert create(auth_client, today_payload).status_code == 201


def test_the_day_is_checked_in_the_requests_own_time_zone(auth_client):
    """Kiritimati is 14 hours ahead of UTC: its yesterday can be New York's today."""
    zone = "Pacific/Kiritimati"
    yesterday_there = (local_today(zone) - timedelta(days=1)).isoformat()
    payload = request_payload(
        timeZone=zone, day=yesterday_there, answersBy=utc_text(timezone.now() + timedelta(minutes=5))
    )
    assert create(auth_client, payload).status_code == 400
    tomorrow_there = (local_today(zone) + timedelta(days=1)).isoformat()
    assert create(auth_client, {**payload, "day": tomorrow_there}).status_code == 201


def test_the_deadline_is_checked_against_the_range_in_the_requests_time_zone(auth_client):
    """8 PM in Los Angeles is 11 PM in New York."""
    zone = "America/Los_Angeles"
    day = (local_today(zone) + timedelta(days=1)).isoformat()
    payload = request_payload(timeZone=zone, day=day)
    assert create(auth_client, {**payload, "answersBy": at(day, 22, zone=TZ)}).status_code == 201
    assert create(auth_client, {**payload, "answersBy": at(day, 23, 1, zone=TZ)}).status_code == 400


# --- GI-4: the owner reads every answer; everyone else gets 404 ------------------------------


@pytest.fixture
def group(profile):
    return make_request(profile)


def owner_get(client, slug):
    return client.get(f"/api/plan-requests/{slug}/")


def test_the_owner_reads_the_request_with_every_answer_oldest_first(auth_client, group):
    maya = add_answer(group, name="Maya", budget=20, free_from=time(12), free_until=time(18), stars=[MET, TACOS])
    jordan = add_answer(group, name="Jordan", budget=150, free_from=time(14, 30), free_until=time(20), stars=[])
    response = owner_get(auth_client, group.slug)

    assert response.status_code == 200
    body = response.json()
    assert set(body) == REQUEST_KEYS
    assert body["slug"] == group.slug and body["status"] == "open"
    assert [(a["id"], a["name"], a["budget"], a["freeFrom"], a["freeUntil"], a["stars"]) for a in body["answers"]] == [
        (str(maya.id), "Maya", 20, "12:00", "18:00", [MET, TACOS]),
        (str(jordan.id), "Jordan", 150, "14:30", "20:00", []),
    ]
    first = body["answers"][0]
    assert set(first) == {"id", "name", "budget", "freeFrom", "freeUntil", "stars", "createdAt", "updatedAt"}
    assert first["createdAt"] == utc_text(maya.created_at)
    assert maya.responder not in response.content.decode()


def test_the_owner_reads_a_request_with_no_answers_yet(auth_client, group):
    assert owner_get(auth_client, group.slug).json()["answers"] == []


def test_status_says_closed_once_the_deadline_passes(auth_client, group):
    GroupRequest.objects.filter(pk=group.pk).update(answers_by=timezone.now() - timedelta(seconds=1))
    assert owner_get(auth_client, group.slug).json()["status"] == "closed"


def test_status_says_built_with_the_plans_slug(auth_client, group, profile):
    from plandit.shares.models import SharedPlan

    shared = SharedPlan.objects.create(owner=profile, plan_id=uuid.uuid4(), data={})
    GroupRequest.objects.filter(pk=group.pk).update(status="built", shared_plan=shared)
    body = owner_get(auth_client, group.slug).json()
    assert (body["status"], body["planSlug"]) == ("built", shared.slug)

    shared.delete()  # stop sharing the built plan
    body = owner_get(auth_client, group.slug).json()
    assert (body["status"], body["planSlug"]) == ("built", None)


@pytest.mark.parametrize("path", ["close/", "close"])
def test_the_owner_closes_the_request(auth_client, group, path):
    response = auth_client.post(f"/api/plan-requests/{group.slug}/{path}")
    assert response.status_code == 204
    group.refresh_from_db()
    assert group.status == "closed"
    assert owner_get(auth_client, group.slug).json()["status"] == "closed"
    assert auth_client.post(f"/api/plan-requests/{group.slug}/{path}").status_code == 204  # again: still closed


def test_closing_a_built_request_leaves_it_built(auth_client, group):
    GroupRequest.objects.filter(pk=group.pk).update(status="built")
    assert auth_client.post(f"/api/plan-requests/{group.slug}/close/").status_code == 204
    group.refresh_from_db()
    assert group.status == "built"


def test_the_owner_deletes_the_request_and_its_answers(auth_client, group, profile):
    add_answer(group, name="Maya")
    other = add_answer(make_request(profile), name="Jordan")

    assert auth_client.delete(f"/api/plan-requests/{group.slug}/").status_code == 204
    assert not GroupRequest.objects.filter(pk=group.pk).exists()
    assert list(GroupAnswer.objects.all()) == [other]
    assert auth_client.delete(f"/api/plan-requests/{group.slug}/").status_code == 404
    assert owner_get(auth_client, group.slug).status_code == 404


@pytest.mark.parametrize("case", [str.upper, str.lower], ids=["upper-case", "lower-case"])
def test_the_owner_removes_an_answer_by_its_id_in_either_case(auth_client, group, case):
    """Brief GS-4: the organizer can remove any answer. The app sends Swift UUIDs, in upper case."""
    maya = add_answer(group, name="Maya")
    add_answer(group, name="Jordan")
    response = auth_client.delete(f"/api/plan-requests/{group.slug}/answers/{case(str(maya.id))}/")
    assert response.status_code == 204
    assert [a["name"] for a in owner_get(auth_client, group.slug).json()["answers"]] == ["Jordan"]
    assert auth_client.delete(f"/api/plan-requests/{group.slug}/answers/{maya.id}/").status_code == 404


def test_an_answer_can_only_be_removed_through_its_own_request(auth_client, group, profile):
    other = make_request(profile)
    maya = add_answer(group, name="Maya")
    assert auth_client.delete(f"/api/plan-requests/{other.slug}/answers/{maya.id}/").status_code == 404
    assert GroupAnswer.objects.count() == 1


def owner_calls(client, slug, answer_id):
    return {
        "get": lambda: client.get(f"/api/plan-requests/{slug}/"),
        "close": lambda: client.post(f"/api/plan-requests/{slug}/close/"),
        "close without a slash": lambda: client.post(f"/api/plan-requests/{slug}/close"),
        "delete": lambda: client.delete(f"/api/plan-requests/{slug}/"),
        "remove an answer": lambda: client.delete(f"/api/plan-requests/{slug}/answers/{answer_id}/"),
        "remove an answer, upper case": lambda: client.delete(
            f"/api/plan-requests/{slug}/answers/{str(answer_id).upper()}/"
        ),
    }


def test_every_owner_endpoint_is_404_for_another_account(other_client, group):
    maya = add_answer(group, name="Maya")
    for label, call in owner_calls(other_client, group.slug, maya.id).items():
        response = call()
        assert response.status_code == 404, label
        assert "Maya" not in response.content.decode(), label
    group.refresh_from_db()
    assert group.status == "open"
    assert GroupAnswer.objects.count() == 1


def test_owner_endpoints_need_an_account(api_client, group):
    maya = add_answer(group, name="Maya")
    for label, call in owner_calls(api_client, group.slug, maya.id).items():
        assert call().status_code in (401, 403), label
    group.refresh_from_db()
    assert group.status == "open"
    assert GroupAnswer.objects.count() == 1


def test_unknown_requests_and_answers_are_404_for_the_owner_too(auth_client, group):
    for label, call in owner_calls(auth_client, "doesnotexist", uuid.uuid4()).items():
        assert call().status_code == 404, label
    assert auth_client.delete(f"/api/plan-requests/{group.slug}/answers/{uuid.uuid4()}/").status_code == 404
    for bad in ("not-a-uuid", "1234", "%20"):
        response = auth_client.delete(f"/api/plan-requests/{group.slug}/answers/{bad}/")
        assert response.status_code == 404, bad
        assert "text/html" not in response.get("Content-Type", ""), bad  # the API's 404, not Django's page


def test_the_owner_read_purges_expired_requests(auth_client, group, profile):
    expired = make_request(profile, day=local_today() - timedelta(days=31))
    add_answer(expired)
    owner_get(auth_client, group.slug)
    assert not GroupRequest.objects.filter(pk=expired.pk).exists()
    assert not GroupAnswer.objects.exists()
