"""Friends' input links (group plans, mode 2, slice G2a; brief GI-1 to GI-8, GS-1 to GS-5).

The organizer's app creates a request (places, a day, a time range and a deadline) and sends its
/g/ link. Friends answer on the page without an account; the organizer reads the answers through
the owner API and builds the plan on the phone, then shares it with the request's slug."""

import copy
import hashlib
import re
import time as clock_module
import uuid
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import pytest
from django.contrib.staticfiles import finders
from django.db import IntegrityError, connection, transaction
from django.test import Client
from django.utils import timezone
from django.utils.html import escape

from plandit.core import public_forms, retention
from plandit.plans import request_views
from plandit.plans.models import GroupAnswer, GroupRequest
from plandit.shares.models import ShareAnswer
from tests.test_answers import csrf_browser, empty_throttle_cache, form_token, html, new_browser  # noqa: F401
from tests.test_shares import PUBLIC_PAGE_CSP

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


def test_requests_are_registered_for_expiry_30_days_after_their_day_and_locked_first():
    """Locked first, as account deletion locks them (tests/test_account_deletion_races.py)."""
    rules = [rule for rule in retention.RULES if rule.model is GroupRequest]
    assert [(rule.date_field, rule.days, rule.lock_first) for rule in rules] == [("day", 30, True)]


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


def test_request_links_use_the_site_address_once_configured(auth_client, browser, settings):
    settings.REQUEST_BASE_URL = "https://plandit.app"
    body = create(auth_client, request_payload()).json()
    assert body["url"] == f"https://plandit.app/g/{body['slug']}"
    page = html(request_page(browser, body["slug"]))
    assert f'<meta property="og:url" content="https://plandit.app/g/{body["slug"]}">' in page


def test_request_links_stay_on_this_host_when_only_share_links_move(auth_client, browser, settings):
    """/p/ links can move to the site before it forwards /g/, so /g/ links have their own setting."""
    settings.SHARE_BASE_URL = "https://plandit.app"
    settings.REQUEST_BASE_URL = ""
    body = create(auth_client, request_payload()).json()
    assert body["url"] == f"http://testserver/g/{body['slug']}"
    assert owner_get(auth_client, body["slug"]).json()["url"] == body["url"]
    page = html(request_page(browser, body["slug"]))
    assert f'<meta property="og:url" content="http://testserver/g/{body["slug"]}">' in page


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


# --- The public page: /g/<slug> ------------------------------------------------------------


@pytest.fixture
def browser():
    return Client()


@pytest.fixture
def clock(monkeypatch):
    """The rate limit's clock, at the start of an hour."""
    now = {"t": 1_800_000_000.0 - 1_800_000_000.0 % 3600}
    monkeypatch.setattr(clock_module, "time", lambda: now["t"])
    return now


def friend_answer(
    client, slug, name="Maya", budget="40", free_from="13:00", free_until="18:00", stars=(TACOS,), **extra
):
    """Submit the page's form the way a browser does: the chosen budget, the two times, and each
    ticked place as `star`. A field given as None isn't sent."""
    data = {"name": name, "budget": budget, "free_from": free_from, "free_until": free_until}
    data = {key: value for key, value in data.items() if value is not None}
    if stars:
        data["star"] = list(stars)
    return client.post(f"/g/{slug}/answer", data, **extra)


def take_back_request(client, slug, **extra):
    return client.post(f"/g/{slug}/answer/delete", {}, **extra)


def request_page(client, slug):
    return client.get(f"/g/{slug}")


def stored() -> tuple:
    answer = GroupAnswer.objects.get()
    return answer.name, answer.budget, answer.free_from, answer.free_until, answer.stars


# --- GI-2: a friend answers with a first name, a budget, a free window and up to 3 stars -----


def test_a_friend_answers_and_goes_back_to_the_page(browser, group):
    response = friend_answer(browser, group.slug, stars=(TACOS, MET))
    assert response.status_code == 303
    assert response["Location"] == f"/g/{group.slug}"
    assert stored() == ("Maya", 40, time(13), time(18), [MET, TACOS])  # in the request's order


def test_the_page_shows_the_places_their_costs_and_the_deadline(browser, group):
    body = html(request_page(browser, group.slug))
    assert '<h2 id="places-title">The places (4)</h2>' in body
    assert "4 places" not in body
    for place in PLACES:
        assert escape(place["name"]) in body
        assert f"{place['neighborhood']} · {place['kind']}" in body
        assert place["costText"] in body
    assert f"Answers by {request_views.deadline_text(group)}" in body
    assert request_views.day_text(group.day) in body
    assert "12 PM to 8 PM" in body


@pytest.mark.parametrize(
    ("moment", "text"),
    [
        (time(12), "12 PM"),
        (time(20), "8 PM"),
        (time(12, 30), "12:30 PM"),
        (time(0), "12 AM"),
        (time(9, 5), "9:05 AM"),
        (time(23, 59), "11:59 PM"),
    ],
)
def test_times_are_written_the_way_the_app_writes_them(moment, text):
    assert request_views.clock_text(moment) == text


def test_the_day_and_the_deadline_are_written_out(profile):
    group = make_request(profile, answers_by=datetime(2026, 11, 28, 2, tzinfo=UTC))
    assert request_views.day_text(date(2026, 11, 28)) == "Saturday, November 28"
    # 2 AM in UTC is 9 PM the evening before in the request's own time zone.
    assert request_views.deadline_text(group) == "Friday, November 27 at 9 PM"


def test_the_form_starts_at_the_whole_range_with_no_stars(browser, group):
    body = html(request_page(browser, group.slug))
    assert re.search(r'<input[^>]*type="time"[^>]*name="free_from"[^>]*min="12:00" max="20:00" value="12:00"', body)
    assert re.search(r'<input[^>]*type="time"[^>]*name="free_until"[^>]*min="12:00" max="20:00" value="20:00"', body)
    assert "Your budget for the day, train included" in body
    assert "Star up to 3 places you want most." in body
    assert not re.search(r'name="star"[^>]* checked', body)


def budget_select(body) -> str:
    match = re.search(r'<select id="answer-budget" name="budget"[^>]*>(.*?)</select>', body, re.S)
    assert match, "no budget select"
    return match.group(0)


def selected_budget(body):
    """The value of the budget's selected option, or None when none is."""
    match = re.search(r'<option value="([^"]*)" selected>', budget_select(body))
    return match.group(1) if match else None


def test_the_budget_is_a_choice_of_0_to_150_dollars_in_5_dollar_steps_with_none_chosen(browser, group):
    """Brief GI-2, changed from the architecture's slider: a slider can't show its value without
    JavaScript, and its starting point would answer for a friend who didn't move it."""
    select = budget_select(html(request_page(browser, group.slug)))
    assert re.search(r'<select id="answer-budget" name="budget" required[ >]', select)
    options = re.findall(r'<option value="([^"]*)"[^>]*>([^<]*)</option>', select)
    assert options[0] == ("", "Choose your budget")
    assert options[1:] == [(str(n), f"${n}") for n in range(0, 151, 5)]
    assert selected_budget(html(request_page(browser, group.slug))) is None
    assert 'class="scale"' not in html(request_page(browser, group.slug))


def test_the_name_field_says_who_sees_the_answer(browser, group):
    assert "Only the person who sent this link sees your answer." in html(request_page(browser, group.slug))


def test_stars_are_stored_in_the_requests_own_spelling_and_order_and_once_each(browser, group):
    friend_answer(browser, group.slug, stars=(TACOS.lower(), TACOS, MET.lower()))
    assert GroupAnswer.objects.get().stars == [MET, TACOS]


def test_stars_for_places_not_in_the_request_are_ignored(browser, group):
    friend_answer(browser, group.slug, stars=(str(uuid.uuid4()), "the-met", TACOS))
    assert GroupAnswer.objects.get().stars == [TACOS]


GOOD_ANSWERS = {
    "no stars": {"stars": ()},
    "3 stars": {"stars": (MET, TACOS, HIGH_LINE)},
    "a budget of $0": {"budget": "0"},
    "a budget of $150": {"budget": "150"},
    "the whole range": {"free_from": "12:00", "free_until": "20:00"},
    "a minute's window": {"free_from": "19:59", "free_until": "20:00"},
    "times with seconds, as some browsers send them": {"free_from": "13:00:00", "free_until": "18:30:00"},
    "a name with an apostrophe": {"name": "D'Andre"},
}


@pytest.mark.parametrize("fields", GOOD_ANSWERS.values(), ids=GOOD_ANSWERS.keys())
def test_answers_at_the_edges_are_accepted(browser, group, fields):
    assert friend_answer(browser, group.slug, **fields).status_code == 303
    assert GroupAnswer.objects.count() == 1


BUDGET_MESSAGE = "Choose a budget from $0 to $150."
TIMES_MESSAGE = "Choose times between 12 PM and 8 PM, with the end after the start."
BAD_ANSWERS = {
    "no budget": ({"budget": None}, BUDGET_MESSAGE),
    "an empty budget": ({"budget": ""}, BUDGET_MESSAGE),
    "a budget over $150": ({"budget": "151"}, BUDGET_MESSAGE),
    "a negative budget": ({"budget": "-1"}, BUDGET_MESSAGE),
    "cents": ({"budget": "40.5"}, BUDGET_MESSAGE),
    "a budget that isn't a number": ({"budget": "forty"}, BUDGET_MESSAGE),
    "a budget with an exponent": ({"budget": "1e2"}, BUDGET_MESSAGE),
    "a budget that isn't a multiple of $5": ({"budget": "42"}, BUDGET_MESSAGE),
    "a budget of $149": ({"budget": "149"}, BUDGET_MESSAGE),
    "free from before the range": ({"free_from": "11:59"}, TIMES_MESSAGE),
    "free until after the range": ({"free_until": "20:01"}, TIMES_MESSAGE),
    "until before from": ({"free_from": "18:00", "free_until": "13:00"}, TIMES_MESSAGE),
    "until the same as from": ({"free_from": "13:00", "free_until": "13:00"}, TIMES_MESSAGE),
    "no from": ({"free_from": None}, TIMES_MESSAGE),
    "an empty until": ({"free_until": ""}, TIMES_MESSAGE),
    "a time that isn't one": ({"free_from": "1pm"}, TIMES_MESSAGE),
    "hour 25": ({"free_until": "25:00"}, TIMES_MESSAGE),
    "4 stars": ({"stars": (MET, TACOS, HIGH_LINE, PIZZA)}, "Star up to 3 places."),
    "no name": ({"name": ""}, "Enter your first name."),
    "a name over 30 characters": ({"name": "A" * 31}, "Use 30 characters or fewer."),
    "a name with a digit": ({"name": "Maya2"}, "Use letters, spaces, hyphens and apostrophes only."),
}


@pytest.mark.parametrize(("fields", "message"), BAD_ANSWERS.values(), ids=BAD_ANSWERS.keys())
def test_bad_answers_show_the_form_again_with_the_reason(browser, group, fields, message):
    response = friend_answer(browser, group.slug, **fields)

    assert response.status_code == 400
    body = html(response)
    assert escape(message) in body
    assert 'id="answer"' in body and "The Met" in body  # the whole page, not a bare error
    assert not GroupAnswer.objects.exists()
    assert "pa" not in response.cookies
    assert response["Cache-Control"] == "private, no-store"
    assert response["Content-Security-Policy"] == PUBLIC_PAGE_CSP


def test_a_blocked_name_is_refused(browser, group, monkeypatch):
    monkeypatch.setattr(public_forms, "name_blocklist", lambda: frozenset({"blockedword"}))
    response = friend_answer(browser, group.slug, name="Blockedword")
    assert response.status_code == 400
    assert escape("That name can't be used here. Try another.") in html(response)
    assert not GroupAnswer.objects.exists()


def test_the_form_keeps_what_was_typed_when_it_comes_back(browser, group):
    body = html(friend_answer(browser, group.slug, name="Maya!", budget="35", free_from="14:30", stars=(MET, PIZZA)))
    assert 'value="Maya!"' in body
    assert selected_budget(body) == "35"
    assert re.search(r'name="free_from"[^>]* value="14:30"', body)
    assert re.search(r'name="free_until"[^>]* value="18:00"', body)
    assert re.search(rf'name="star" value="{MET}"[^>]* checked', body)
    assert re.search(rf'name="star" value="{PIZZA}"[^>]* checked', body)
    assert not re.search(rf'name="star" value="{TACOS}"[^>]* checked', body)


@pytest.mark.parametrize("budget", ["999", "42", "", "forty"])
def test_values_the_form_cannot_show_come_back_as_its_starting_values(browser, group, budget):
    body = html(friend_answer(browser, group.slug, budget=budget, free_from="nope", free_until="23:00"))
    assert selected_budget(body) is None  # back to "Choose your budget"
    assert re.search(r'name="free_from"[^>]* value="12:00"', body)
    assert re.search(r'name="free_until"[^>]* value="23:00"', body)  # a time: kept, for the friend to fix


def test_the_answer_cookie_is_for_this_link_only_and_only_its_hash_is_stored(browser, group):
    cookie = friend_answer(browser, group.slug).cookies["pa"]
    assert cookie["path"] == f"/g/{group.slug}"
    assert cookie["httponly"] is True and cookie["secure"] is True and cookie["samesite"] == "Lax"
    answer = GroupAnswer.objects.get()
    assert answer.responder == hashlib.sha256(cookie.value.encode()).hexdigest()
    assert cookie.value not in str(GroupAnswer.objects.values().get())


DAY = 24 * 60 * 60


@pytest.mark.parametrize(("days_ahead", "cookie_days"), [(0, 30), (1, 31), (14, 44)])
def test_the_cookie_lasts_until_the_answer_is_deleted(browser, profile, days_ahead, cookie_days):
    """Answers go 30 days after the request's day (brief GS-5), and the cookie with them."""
    group = make_request(
        profile,
        day=timezone.localdate() + timedelta(days=days_ahead),
        answers_by=timezone.now() + timedelta(minutes=5),
    )
    cookie = friend_answer(browser, group.slug).cookies["pa"]
    assert int(cookie["max-age"]) == cookie_days * DAY


def test_the_page_itself_sets_no_answer_cookie(browser, group):
    assert "pa" not in request_page(browser, group.slug).cookies


# --- GI-2: the same browser changes or takes back its answer; nobody else can ---------------


def test_the_same_browser_changes_its_answer(browser, group):
    token = friend_answer(browser, group.slug).cookies["pa"].value
    first = GroupAnswer.objects.get()
    response = friend_answer(browser, group.slug, name="Maya J", budget="20", free_until="20:00", stars=())

    assert response.status_code == 303
    assert response.cookies["pa"].value == token  # the same cookie, renewed
    changed = GroupAnswer.objects.get()
    assert changed.id == first.id and changed.created_at == first.created_at
    assert stored() == ("Maya J", 20, time(13), time(20), [])


def test_the_same_browser_sees_its_own_answer(browser, group):
    friend_answer(browser, group.slug, name="Jordan", budget="25", free_from="14:00", free_until="19:30", stars=(MET,))
    body = html(request_page(browser, group.slug))
    assert "You've answered: <strong>$25</strong>, free <strong>2 PM to 7:30 PM</strong>." in body
    assert 'value="Jordan"' in body
    assert selected_budget(body) == "25"
    assert re.search(r'name="free_from"[^>]* value="14:00"', body)
    assert re.search(r'name="free_until"[^>]* value="19:30"', body)
    assert re.search(rf'name="star" value="{MET}"[^>]* checked', body)
    assert "Take back my answer" in body


def test_a_saved_budget_of_0_dollars_is_chosen_again(browser, group):
    friend_answer(browser, group.slug, budget="0")
    assert selected_budget(html(request_page(browser, group.slug))) == "0"


def test_another_browser_gets_its_own_answer_and_cannot_touch_the_first(browser, group):
    friend_answer(browser, group.slug, name="Maya", budget="40")
    other = new_browser()
    friend_answer(other, group.slug, name="Maya", budget="90")
    assert GroupAnswer.objects.count() == 2
    assert take_back_request(other, group.slug).status_code == 303

    assert stored()[:2] == ("Maya", 40)
    other_page = html(request_page(other, group.slug))
    assert "You've answered" not in other_page and "Take back my answer" not in other_page


def test_a_forged_cookie_is_just_a_new_browser(browser, group):
    friend_answer(browser, group.slug, name="Maya")
    forger = Client()
    forger.cookies["pa"] = "x" * 43
    friend_answer(forger, group.slug, name="Mallory")
    assert sorted(GroupAnswer.objects.values_list("name", flat=True)) == ["Mallory", "Maya"]


def test_the_same_browser_takes_back_its_answer(browser, group):
    friend_answer(browser, group.slug)
    response = take_back_request(browser, group.slug)
    assert response.status_code == 303
    assert response["Location"] == f"/g/{group.slug}"
    assert not GroupAnswer.objects.exists()
    assert "You've answered" not in html(request_page(browser, group.slug))


def test_taking_back_without_an_answer_does_nothing(browser, group):
    add_answer(group, name="Maya")
    assert take_back_request(browser, group.slug).status_code == 303
    assert "pa" not in browser.cookies
    assert GroupAnswer.objects.count() == 1


def test_a_cookie_only_counts_on_its_own_link(browser, group, profile):
    other = make_request(profile)
    friend_answer(browser, group.slug, name="Maya")
    # The test client sends the cookie to every path, unlike a browser; it still only counts here.
    friend_answer(browser, other.slug, name="Maya")
    assert GroupAnswer.objects.count() == 2
    take_back_request(browser, other.slug)
    assert GroupAnswer.objects.get().request == group


def test_a_share_links_cookie_does_not_answer_for_a_request(auth_client, browser, group):
    """Both pages use the `pa` cookie, each on its own path. Answers are kept per link, so even a
    client that sends one cookie everywhere only changes the answer on the link it posts to."""
    from tests.test_answers import answer, answers_payload
    from tests.test_shares import share

    plan_slug = share(auth_client, answers_payload()).json()["slug"]
    answer(browser, plan_slug, name="Maya")
    friend_answer(browser, group.slug, name="Maya")
    assert GroupAnswer.objects.count() == 1
    take_back_request(browser, group.slug)
    assert not GroupAnswer.objects.exists()
    assert ShareAnswer.objects.count() == 1


# --- GI-8: a friend sees how many answered, never anyone else's answer ---------------------


def test_the_page_shows_only_how_many_answered(browser, group):
    # The deadline on the hour, so the page's own times can't look like a friend's.
    group.answers_by = datetime.combine(group.day, time(20), tzinfo=ZoneInfo(TZ))
    group.save(update_fields=["answers_by"])
    add_answer(group, name="Zelda", budget=137, free_from=time(13, 37), free_until=time(19, 41), stars=[PIZZA])
    add_answer(group, name="Quinn", budget=123, free_from=time(12, 23), free_until=time(17, 47), stars=[PIZZA])
    body = html(request_page(browser, group.slug))

    assert "2 friends answered" in body
    for text in ("Zelda", "Quinn", "$137", "$123", '"137"', '"123"', ">137<", ">123<"):
        assert text not in body, text
    for text in ("13:37", "1:37 PM", "19:41", "7:41 PM", "12:23", "17:47", "5:47 PM"):
        assert text not in body, text
    assert not re.search(rf'name="star" value="{PIZZA}"[^>]* checked', body)


def test_one_answer_is_counted_as_one_friend(browser, group):
    add_answer(group, name="Zelda")
    body = html(request_page(browser, group.slug))
    assert "1 friend answered" in body and "friends answered" not in body


def test_no_answers_yet_shows_no_count(browser, group):
    assert "answered" not in html(request_page(browser, group.slug))


def test_the_count_includes_the_friends_own_answer(browser, group):
    add_answer(group, name="Zelda")
    friend_answer(browser, group.slug)
    body = html(request_page(browser, group.slug))
    assert "2 friends answered" in body and "Zelda" not in body


# --- GI-3: after the deadline, or once closed or built, the link stops taking answers -------


CLOSED = "This plan isn't taking answers any more"


def past_deadline(group):
    GroupRequest.objects.filter(pk=group.pk).update(answers_by=timezone.now() - timedelta(seconds=1))


def closed_by_the_organizer(group):
    GroupRequest.objects.filter(pk=group.pk).update(status="closed")


def built_and_no_longer_shared(group):
    GroupRequest.objects.filter(pk=group.pk).update(status="built", shared_plan=None)


@pytest.mark.parametrize("close", [past_deadline, closed_by_the_organizer, built_and_no_longer_shared])
def test_a_closed_request_says_so_and_refuses_answers(browser, group, close):
    friend_answer(browser, group.slug, name="Maya")
    close(group)

    page = request_page(browser, group.slug)
    assert page.status_code == 200
    body = html(page)
    assert CLOSED in body
    assert "Ask whoever sent you this link for the plan." in body
    assert 'id="answer"' not in body and 'name="budget"' not in body
    assert page["Cache-Control"] == "private, no-store"
    assert page["Content-Security-Policy"] == PUBLIC_PAGE_CSP

    refused = friend_answer(new_browser(), group.slug, name="Late")
    assert refused.status_code == 410
    assert CLOSED in html(refused)
    assert "pa" not in refused.cookies
    assert refused["Cache-Control"] == "private, no-store"
    assert list(GroupAnswer.objects.values_list("name", flat=True)) == ["Maya"]


def test_a_closed_request_still_lets_a_friend_take_back_their_answer(browser, group):
    friend_answer(browser, group.slug, name="Maya")
    past_deadline(group)
    assert "Take back my answer" in html(request_page(browser, group.slug))
    assert "Take back my answer" not in html(request_page(new_browser(), group.slug))
    assert take_back_request(browser, group.slug).status_code == 303
    assert not GroupAnswer.objects.exists()


def test_a_change_after_the_deadline_is_refused(browser, group):
    friend_answer(browser, group.slug, budget="40")
    past_deadline(group)
    assert friend_answer(browser, group.slug, budget="10").status_code == 410
    assert GroupAnswer.objects.get().budget == 40


# --- GI-7: once built, the link opens the plan ----------------------------------------------


def built(group, profile):
    """The request marked built straight in the database, with a plan shared for it."""
    from plandit.shares.models import SharedPlan

    shared = SharedPlan.objects.create(owner=profile, plan_id=uuid.uuid4(), data={})
    GroupRequest.objects.filter(pk=group.pk).update(status="built", shared_plan=shared)
    return shared


def test_a_built_request_redirects_to_its_plans_page(browser, group, profile):
    shared = built(group, profile)

    response = request_page(browser, group.slug)
    assert response.status_code == 302
    assert response["Location"] == f"/p/{shared.slug}"
    assert response["Cache-Control"] == "private, no-store"
    assert response["X-Robots-Tag"] == "noindex, nofollow"
    assert friend_answer(browser, group.slug).status_code == 410


def test_once_built_a_friend_who_answered_gets_the_plans_link_and_can_take_back_their_answer(browser, group, profile):
    friend_answer(browser, group.slug, name="Maya")
    shared = built(group, profile)

    page = request_page(browser, group.slug)
    assert page.status_code == 200
    body = html(page)
    assert f"<h1>Abraham's plan for {request_views.day_text(group.day)} is ready</h1>" in body
    assert re.search(rf'<a class="cta" href="/p/{shared.slug}">See the plan</a>', body)
    assert "Taking your answer back won't change the plan." in body
    assert re.findall(r'<form[^>]*action="([^"]+)"', body) == [f"/g/{group.slug}/answer/delete"]
    assert "Take back my answer" in body
    assert 'name="budget"' not in body and "Maya" not in body
    assert f"%2Fg%2F{group.slug}" in body  # the report link names this page
    assert page["Cache-Control"] == "private, no-store"
    assert page["X-Robots-Tag"] == "noindex, nofollow"
    assert page["Referrer-Policy"] == "same-origin"
    assert page["Content-Security-Policy"] == PUBLIC_PAGE_CSP

    taken_back = take_back_request(browser, group.slug)
    assert (taken_back.status_code, taken_back["Location"]) == (303, f"/g/{group.slug}")
    assert not GroupAnswer.objects.exists()
    after = request_page(browser, group.slug)
    assert (after.status_code, after["Location"]) == (302, f"/p/{shared.slug}")


def test_once_built_everyone_without_an_answer_on_it_goes_straight_to_the_plan(browser, group, profile):
    friend_answer(browser, group.slug, name="Maya")
    add_answer(group, name="Zelda")
    elsewhere = new_browser()
    friend_answer(elsewhere, make_request(profile).slug, name="Sam")  # answered another link only
    forger = Client()
    forger.cookies["pa"] = "x" * 43
    shared = built(group, profile)

    for client in (new_browser(), elsewhere, forger):
        response = request_page(client, group.slug)
        assert (response.status_code, response["Location"]) == (302, f"/p/{shared.slug}")
        assert response["Cache-Control"] == "private, no-store"
    assert request_page(browser, group.slug).status_code == 200


def test_once_built_with_its_plan_no_longer_shared_an_answer_gets_the_closed_page(browser, group):
    friend_answer(browser, group.slug, name="Maya")
    built_and_no_longer_shared(group)
    body = html(request_page(browser, group.slug))
    assert CLOSED in body and "Take back my answer" in body and "See the plan" not in body


# --- Whose link it is: the organizer's first name on the form and the ready page --------------


FORM_HEADING = '<h2 id="answer-title">What works for you?</h2>'


def named(profile, name: str):
    profile.name = name
    profile.save(update_fields=["name"])


def form_heading(name: str) -> str:
    return f'<h2 id="answer-title">{name} wants to know what works for you</h2>'


def ready_heading(group, name: str | None = None) -> str:
    whose = f"{name}'s plan" if name else "The plan"
    return f"<h1>{whose} for {request_views.day_text(group.day)} is ready</h1>"


def ready_page(browser, group, profile) -> str:
    friend_answer(browser, group.slug, name="Jordan")
    built(group, profile)
    page = request_page(browser, group.slug)
    assert page.status_code == 200
    return html(page)


@pytest.mark.parametrize(
    ("name", "shown"),
    [("Maya Lopez", "Maya"), ("  Jordan   Lee ", "Jordan"), ("Mary-Ann Okafor", "Mary-Ann"), ("A" * 40, "A" * 30)],
)
def test_the_form_and_the_ready_page_name_the_organizer_by_first_name(browser, group, profile, name, shown):
    """The first word of the organizer's profile name, at most 30 characters, as group plan members
    see each other (GroupMember.display_name)."""
    named(profile, name)
    body = html(request_page(browser, group.slug))
    assert form_heading(shown) in body
    assert FORM_HEADING not in body
    assert ready_heading(group, shown) in ready_page(browser, group, profile)


def test_only_the_first_name_is_shown(browser, group, profile):
    named(profile, "Maya Lopez")
    assert "Lopez" not in html(request_page(browser, group.slug))
    assert "Lopez" not in ready_page(browser, group, profile)


def test_a_form_sent_back_with_an_error_still_names_the_organizer(browser, group, profile):
    named(profile, "Maya Lopez")
    response = friend_answer(browser, group.slug, name="")
    assert response.status_code == 400
    assert form_heading("Maya") in html(response)


@pytest.mark.parametrize("name", ["", "   ", "🎉 Party", "J. Lee", "<b>Al</b>"])
def test_without_a_first_name_the_pages_are_as_before(browser, group, profile, name):
    """No name, or none that passes the first-name check: the old headings, and no placeholder."""
    named(profile, name)
    body = html(request_page(browser, group.slug))
    assert FORM_HEADING in body
    assert "wants to know" not in body
    ready = ready_page(browser, group, profile)
    assert ready_heading(group) in ready
    assert "'s plan" not in ready


def test_the_organizers_name_is_escaped(browser, group, profile):
    """`<b>Al</b>` isn't a first name, so it's never shown, as markup or as text; a name that is
    one is still HTML-escaped, apostrophes included."""
    named(profile, "<b>Al</b>")
    body = html(request_page(browser, group.slug))
    assert "<b>Al" not in body and "&lt;b&gt;Al" not in body
    named(profile, "D'Andre Smith")
    body = html(request_page(browser, group.slug))
    assert form_heading("D&#x27;Andre") in body
    assert "D'Andre" not in body
    assert ready_heading(group, "D&#x27;Andre") in ready_page(browser, group, profile)


def test_the_not_found_page_never_names_the_organizer(auth_client, browser, group, profile):
    named(profile, "Priya Shah")
    friend_answer(browser, group.slug)
    assert "Priya" not in html(request_page(browser, "doesnotexist"))
    auth_client.delete(f"/api/plan-requests/{group.slug}/")
    for response in (request_page(browser, group.slug), friend_answer(browser, group.slug)):
        assert response.status_code == 404
        assert "Priya" not in html(response)


def test_the_organizers_name_is_not_added_to_the_api(auth_client, group, profile):
    """Only the pages show it; the owner's own JSON is unchanged."""
    named(profile, "Maya Lopez")
    assert "Maya" not in auth_client.get(f"/api/plan-requests/{group.slug}/").content.decode()


# --- Missing links and methods ---------------------------------------------------------------


def test_a_link_that_does_not_exist_is_404_everywhere(browser):
    page = request_page(browser, "doesnotexist")
    assert page.status_code == 404
    assert "This plan isn't shared anymore" in html(page)
    assert page["Content-Security-Policy"] == PUBLIC_PAGE_CSP
    assert friend_answer(browser, "doesnotexist").status_code == 404
    assert take_back_request(browser, "doesnotexist").status_code == 404


def test_a_deleted_request_is_404_and_its_form_posts_to_a_missing_page(auth_client, browser, group):
    friend_answer(browser, group.slug)
    auth_client.delete(f"/api/plan-requests/{group.slug}/")
    assert request_page(browser, group.slug).status_code == 404
    response = friend_answer(browser, group.slug)
    assert response.status_code == 404
    assert "This plan isn't shared anymore" in html(response)
    assert take_back_request(browser, group.slug).status_code == 404


def test_the_answer_urls_only_take_posts(browser, group):
    assert browser.get(f"/g/{group.slug}/answer").status_code == 405
    assert browser.get(f"/g/{group.slug}/answer/delete").status_code == 405
    assert browser.post(f"/g/{group.slug}").status_code == 405


# --- GS-3: CSRF, headers and the policy ------------------------------------------------------


def test_a_post_without_the_csrf_token_is_refused(group):
    client = csrf_browser()
    assert friend_answer(client, group.slug).status_code == 403
    request_page(client, group.slug)  # has the CSRF cookie now, but still no token in the form
    assert friend_answer(client, group.slug).status_code == 403
    assert take_back_request(client, group.slug).status_code == 403
    assert not GroupAnswer.objects.exists()


def test_a_post_with_the_pages_csrf_token_is_accepted(group):
    client = csrf_browser()
    token = form_token(html(request_page(client, group.slug)))
    data = {"csrfmiddlewaretoken": token, "name": "Maya", "budget": "40", "free_from": "13:00", "free_until": "18:00"}
    assert client.post(f"/g/{group.slug}/answer", data).status_code == 303
    token = form_token(html(request_page(client, group.slug)))
    assert client.post(f"/g/{group.slug}/answer/delete", {"csrfmiddlewaretoken": token}).status_code == 303
    assert not GroupAnswer.objects.exists()


def test_the_page_sends_its_origin_so_the_csrf_check_can_pass(group):
    client = csrf_browser()
    response = request_page(client, group.slug)
    assert response["Referrer-Policy"] == "same-origin"
    token = form_token(html(response))
    data = {"csrfmiddlewaretoken": token, "name": "Maya", "budget": "40", "free_from": "13:00", "free_until": "18:00"}
    assert client.post(f"/g/{group.slug}/answer", data, HTTP_ORIGIN="null").status_code == 403
    assert client.post(f"/g/{group.slug}/answer", data, HTTP_ORIGIN="https://evil.example").status_code == 403
    assert client.post(f"/g/{group.slug}/answer", data, HTTP_ORIGIN="http://testserver").status_code == 303


def test_the_pages_are_never_cached(browser, group):
    responses = [
        request_page(browser, group.slug),
        friend_answer(browser, group.slug),
        friend_answer(browser, group.slug, name=""),
        take_back_request(browser, group.slug),
    ]
    for response in responses:
        assert response["Cache-Control"] == "private, no-store", response.status_code
        assert response["X-Robots-Tag"] == "noindex, nofollow"
        assert response["Referrer-Policy"] == "same-origin"
        assert response["Content-Security-Policy"] == PUBLIC_PAGE_CSP


@pytest.mark.parametrize("state", ["open", "closed", "built"])
def test_the_page_fits_its_policy_and_needs_no_javascript(browser, group, profile, state):
    friend_answer(browser, group.slug)
    if state == "closed":
        past_deadline(group)
    elif state == "built":
        built(group, profile)
    body = html(request_page(browser, group.slug))
    assert "<script" not in body and "<style" not in body and " style=" not in body
    assert not re.search(r"<[^>]+\son[a-z]+=", body)  # no inline event handlers
    stylesheets = re.findall(r'<link rel="stylesheet" href="([^"]+)">', body)
    assert stylesheets[0].startswith("https://fonts.googleapis.com/")
    for href in stylesheets[1:]:
        assert href.startswith("/static/"), href
        assert finders.find(href.removeprefix("/static/")), href
    for src in re.findall(r'<img[^>]* src="([^"]+)"', body):
        assert src.startswith("https://plandit.app/"), src
    # Brief GI-2: a budget select, two times and checkboxes, nothing that needs a script.
    types = set(re.findall(r'<input[^>]*type="([^"]+)"', body))
    assert types <= {"hidden", "text", "time", "checkbox"}, types
    forms = re.findall(r'<form[^>]*action="([^"]+)"', body)
    if state == "open":
        assert types == {"hidden", "text", "time", "checkbox"}
        assert re.findall(r'<select[^>]* name="([^"]+)"', body) == ["budget"]
        assert forms == [f"/g/{group.slug}/answer", f"/g/{group.slug}/answer/delete"]
    else:
        assert forms == [f"/g/{group.slug}/answer/delete"]


@pytest.mark.parametrize("found", [True, False])
def test_every_request_page_has_a_report_link(browser, group, found):
    slug = group.slug if found else "doesnotexist"
    body = html(request_page(browser, slug))
    link = re.search(r'<a href="(mailto:support@plandit\.app[^"]*)">Report this page</a>', body)
    assert link, "no report link"
    if found:
        assert f"%2Fg%2F{slug}" in link.group(1)


@pytest.mark.parametrize("state", ["open", "closed", "built"])
def test_links_off_the_page_send_no_referrer(browser, group, profile, state):
    if state == "closed":
        past_deadline(group)
    elif state == "built":
        friend_answer(browser, group.slug)
        built(group, profile)
    body = html(request_page(browser, group.slug))
    links = re.findall(r'<a [^>]*href="https://[^"]*"[^>]*>', body)
    assert len(links) >= 2  # brand, "Make your own plan"
    for link in links:
        rel = re.search(r'rel="([^"]*)"', link)
        assert rel and "noreferrer" in rel.group(1).split(), link


def test_place_names_are_escaped(browser, profile):
    places = copy.deepcopy(PLACES)
    places[0]["name"] = "<b>Tacos</b> & co"
    group = make_request(profile, places=places)
    body = html(request_page(browser, group.slug))
    assert "<b>Tacos</b>" not in body
    assert escape("<b>Tacos</b> & co") in body


# --- GS-2: 20 answers per address per hour on each link, 50 per link -------------------------


def test_the_21st_answer_from_one_address_in_an_hour_is_refused(group, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for n in range(20):
        name = f"Friend {'abcdefghijklmnopqrstu'[n]}"
        assert friend_answer(new_browser(), group.slug, name=name, REMOTE_ADDR="203.0.113.7").status_code == 303, n

    refused = friend_answer(new_browser(), group.slug, name="Late", REMOTE_ADDR="203.0.113.7")
    assert refused.status_code == 429
    assert "Too many answers right now. Please try again later." in html(refused)
    assert refused["Cache-Control"] == "private, no-store"
    assert "pa" not in refused.cookies
    assert GroupAnswer.objects.count() == 20
    assert friend_answer(new_browser(), group.slug, name="Other", REMOTE_ADDR="198.51.100.4").status_code == 303

    clock["t"] += 3600
    assert friend_answer(new_browser(), group.slug, name="Later", REMOTE_ADDR="203.0.113.7").status_code == 303


def test_the_address_limit_is_per_link(group, profile, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    other = make_request(profile)
    for n in range(20):
        name = f"Friend {'abcdefghijklmnopqrstu'[n]}"
        assert friend_answer(new_browser(), group.slug, name=name, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert friend_answer(new_browser(), other.slug, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert friend_answer(new_browser(), group.slug, REMOTE_ADDR="203.0.113.7").status_code == 429


def test_the_address_limit_is_not_shared_with_share_links(auth_client, group, settings, clock):
    """A request and a shared plan could have the same slug; their limits are counted apart."""
    from tests.test_answers import answer, answers_payload
    from tests.test_shares import share

    settings.BEHIND_TRUSTED_PROXY = False
    plan_slug = share(auth_client, answers_payload()).json()["slug"]
    for _ in range(20):
        answer(new_browser(), plan_slug, REMOTE_ADDR="203.0.113.7")
    GroupRequest.objects.filter(pk=group.pk).update(slug=plan_slug)
    assert friend_answer(new_browser(), plan_slug, REMOTE_ADDR="203.0.113.7").status_code == 303


def test_changing_an_answer_counts_against_the_address_too(browser, group, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for _ in range(20):
        assert friend_answer(browser, group.slug, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert friend_answer(browser, group.slug, budget="10", REMOTE_ADDR="203.0.113.7").status_code == 429
    assert GroupAnswer.objects.get().budget == 40


def test_taking_back_an_answer_is_never_refused_by_the_limit(browser, group, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for _ in range(20):
        friend_answer(browser, group.slug, REMOTE_ADDR="203.0.113.7")
    assert take_back_request(browser, group.slug, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert not GroupAnswer.objects.exists()


def fill_request(group, count):
    GroupAnswer.objects.bulk_create(
        GroupAnswer(
            request=group,
            responder=hashlib.sha256(f"seed-{n}".encode()).hexdigest(),
            name=f"Seed {'abcdefghijklmnopqrstuvwxyz'[n % 26]}",
            budget=40,
            free_from=time(12),
            free_until=time(20),
        )
        for n in range(count)
    )


def test_the_51st_answer_on_a_link_is_refused(browser, group):
    friend_answer(browser, group.slug, name="Maya")
    fill_request(group, 49)
    assert GroupAnswer.objects.count() == 50

    refused = friend_answer(new_browser(), group.slug, name="Late")
    assert refused.status_code == 429
    assert escape("This plan isn't taking more answers.") in html(refused)
    assert "Too many answers right now" not in html(refused)
    assert "pa" not in refused.cookies
    assert GroupAnswer.objects.count() == 50
    # Someone who already answered can still change their answer.
    assert friend_answer(browser, group.slug, name="Maya", budget="10").status_code == 303
    assert GroupAnswer.objects.get(name="Maya").budget == 10


def test_the_cap_is_per_link(group, profile):
    fill_request(group, 50)
    assert friend_answer(new_browser(), make_request(profile).slug).status_code == 303


def test_the_organizer_removing_answers_makes_room_again(auth_client, group):
    fill_request(group, 50)
    removed = GroupAnswer.objects.first()
    assert auth_client.delete(f"/api/plan-requests/{group.slug}/answers/{removed.id}/").status_code == 204
    assert friend_answer(new_browser(), group.slug).status_code == 303


# --- GS-5: public posts and the open page purge expired requests ----------------------------


@pytest.mark.parametrize("visit", ["page", "answer", "take back"])
def test_the_public_page_purges_expired_requests(browser, group, profile, visit):
    expired = make_request(profile, day=local_today() - timedelta(days=31))
    add_answer(expired)
    {
        "page": lambda: request_page(browser, group.slug),
        "answer": lambda: friend_answer(browser, group.slug),
        "take back": lambda: take_back_request(browser, group.slug),
    }[visit]()
    assert not GroupRequest.objects.filter(pk=expired.pk).exists()


# --- GI-7: the organizer shares the built plan with the request's slug -----------------------


def share_built(client, slug, plan_id=None):
    from tests.test_shares import plan_payload, share

    return share(client, plan_payload(plan_id, request=slug))


def test_sharing_the_plan_with_the_requests_slug_marks_it_built(auth_client, browser, group):
    from plandit.shares.models import SharedPlan

    response = share_built(auth_client, group.slug)
    assert response.status_code == 201
    shared = SharedPlan.objects.get(slug=response.json()["slug"])
    assert set(response.json()) == {"slug", "url"}
    assert "request" not in shared.data  # used, not stored with the plan

    group.refresh_from_db()
    assert (group.status, group.shared_plan_id) == ("built", shared.pk)
    assert owner_get(auth_client, group.slug).json()["planSlug"] == shared.slug
    page = request_page(browser, group.slug)
    assert (page.status_code, page["Location"]) == (302, f"/p/{shared.slug}")
    assert friend_answer(browser, group.slug).status_code == 410


@pytest.mark.parametrize("state", ["closed", "past the deadline"])
def test_a_closed_request_can_still_be_built(auth_client, group, state):
    """The organizer can build at any time with whoever answered (brief GI-5)."""
    if state == "closed":
        closed_by_the_organizer(group)
    else:
        past_deadline(group)
    assert share_built(auth_client, group.slug).status_code == 201
    group.refresh_from_db()
    assert group.status == "built"


def test_sharing_the_same_plan_again_keeps_the_request_built(auth_client, group):
    plan_id = uuid.uuid4()
    first = share_built(auth_client, group.slug, plan_id).json()["slug"]
    again = share_built(auth_client, group.slug, plan_id)
    assert again.status_code == 200 and again.json()["slug"] == first
    group.refresh_from_db()
    assert (group.status, group.shared_plan.slug) == ("built", first)


def test_building_again_from_another_plan_moves_the_link(auth_client, group):
    share_built(auth_client, group.slug)
    second = share_built(auth_client, group.slug).json()["slug"]
    group.refresh_from_db()
    assert group.shared_plan.slug == second


def test_sharing_without_a_request_leaves_requests_alone(auth_client, group):
    from tests.test_shares import plan_payload, share

    assert share(auth_client, plan_payload()).status_code == 201
    group.refresh_from_db()
    assert (group.status, group.shared_plan_id) == ("open", None)


def test_stopping_sharing_the_built_plan_closes_the_link(auth_client, browser, group):
    slug = share_built(auth_client, group.slug).json()["slug"]
    assert auth_client.delete(f"/api/shares/{slug}/").status_code == 204
    group.refresh_from_db()
    assert (group.status, group.shared_plan_id) == ("built", None)
    assert owner_get(auth_client, group.slug).json()["planSlug"] is None
    page = request_page(browser, group.slug)
    assert page.status_code == 200 and CLOSED in html(page)


def someone_elses_request() -> GroupRequest:
    from plandit.core.models import Profile

    stranger = Profile.objects.create(id=uuid.uuid4(), email="stranger@nyu.edu", name="Stranger")
    return make_request(stranger)


@pytest.mark.parametrize("whose", ["another account's", "unknown"])
def test_only_the_owner_can_mark_a_request_built_and_nothing_else_changes(auth_client, profile, whose):
    from plandit.shares.models import SharedPlan

    target = someone_elses_request() if whose == "another account's" else None
    slug = target.slug if target else "doesnotexi"
    plan_id = uuid.uuid4()
    from tests.test_shares import plan_payload, share

    original = share(auth_client, plan_payload(plan_id, title="Before")).json()["slug"]

    refused = share(auth_client, plan_payload(plan_id, title="After", request=slug))
    assert refused.status_code == 400
    assert refused.json() == {"request": ["No such request."]}  # the same answer either way
    assert SharedPlan.objects.get(slug=original).data["title"] == "Before"  # the update rolled back
    assert share(auth_client, plan_payload(request=slug)).status_code == 400
    assert SharedPlan.objects.count() == 1  # and no new link was made
    if target:
        target.refresh_from_db()
        assert (target.status, target.shared_plan_id) == ("open", None)


def test_an_outsider_cannot_mark_the_organizers_request_built(other_client, browser, group):
    from plandit.shares.models import SharedPlan

    assert share_built(other_client, group.slug).status_code == 400
    assert not SharedPlan.objects.exists()
    group.refresh_from_db()
    assert (group.status, group.shared_plan_id) == ("open", None)
    assert request_page(browser, group.slug).status_code == 200


@pytest.mark.parametrize("bad", ["", None, "not a slug", "abcdefghijk", 12, ["abc"]])
def test_a_request_field_that_isnt_a_slug_is_refused(auth_client, group, bad):
    from plandit.shares.models import SharedPlan

    response = share_built(auth_client, bad)
    assert response.status_code == 400
    assert set(response.json()) == {"request"}
    assert not SharedPlan.objects.exists()
