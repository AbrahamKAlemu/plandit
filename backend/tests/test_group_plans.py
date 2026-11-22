"""Group plans, mode 3: members with accounts edit one shared plan (slice G3a; brief GE-1 to GE-10,
GS-1 to GS-7).

Test ids (ISO-1, VER-3, LIM-2, ...) are the ones in docs/features/group-plans/03-plan_g3-tests.md.
The threaded tests are in test_group_plan_races.py.

Row level security doesn't apply to the API: Django owns the tables, and owners bypass RLS. So the
isolation tests here are what keeps one person's group plans from another (test plan, section 0)."""

import copy
import uuid
from dataclasses import dataclass
from datetime import date, timedelta

import pytest
from django.db import IntegrityError, connection, transaction
from django.utils import timezone
from rest_framework.test import APIClient

from plandit.core import retention
from plandit.core.models import DeletedAccount, Profile
from plandit.groups.models import (
    GROUP_RETENTION_DAYS,
    GroupMember,
    GroupPlan,
    GroupPlanEdit,
    GroupRemoval,
)
from tests.conftest import make_token

pytestmark = pytest.mark.django_db

NEW_TABLES = ["groups_groupplan", "groups_groupmember", "groups_groupplanedit", "groups_groupremoval"]


# --- Helpers ----------------------------------------------------------------------------------


@dataclass
class Person:
    profile: Profile
    client: APIClient

    @property
    def id(self):
        return self.profile.id


def person(name: str, email: str | None = None, *, is_anonymous: bool = False, **fields) -> Person:
    """A profile in the database and a signed-in client for it. Clients don't raise on a 500, so a
    test sees the status code."""
    profile_id = uuid.uuid4()
    handle = (name.split() or ["someone"])[0].lower()
    email = "" if is_anonymous else (email or f"{handle}-{profile_id.hex[:6]}@columbia.edu")
    profile = Profile.objects.create(id=profile_id, email=email, name=name, is_anonymous=is_anonymous, **fields)
    client = APIClient(raise_request_exception=False)
    token = make_token(profile_id, email=email, name=name, is_anonymous=is_anonymous)
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    return Person(profile, client)


def anonymous_client() -> APIClient:
    return APIClient(raise_request_exception=False)


def deleted_client() -> APIClient:
    """A still-valid token for an account that was deleted (tests/test_account_delete.py:172)."""
    profile_id = uuid.uuid4()
    DeletedAccount.objects.create(id=profile_id)
    client = APIClient(raise_request_exception=False)
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {make_token(profile_id)}")
    return client


def new_id() -> str:
    """The app's ids are Swift UUIDs, which encode in upper case."""
    return str(uuid.uuid4()).upper()


def stop_json(stop_id=None, name="The Met") -> dict:
    """One `PlanStop` as the app encodes it (ios/Plandit/Models/DayPlan.swift)."""
    return {
        "id": stop_id or new_id(),
        "place": {"id": new_id(), "name": name, "category": "culture", "neighborhood": "Upper East Side"},
        "start": 785_001_000.0,
        "durationMinutes": 90,
        "estimatedCost": 30,
        "status": "upcoming",
        "costItems": [],
        "costIsCustom": False,
    }


def plan_json(plan_id=None, stops=None, **overrides) -> dict:
    """A `DayPlan` as the app encodes it: id, date, title, budget, stops, legs and extras."""
    stops = stops if stops is not None else [stop_json(name="The Met"), stop_json(name="Los Tacos No. 1")]
    legs = [
        {
            "id": new_id(),
            "fromStopID": stops[i]["id"],
            "toStopID": stops[i + 1]["id"],
            "mode": "subway",
            "minutes": 25,
            "miles": 3.1,
            "cost": 2.9,
            "isChosen": False,
        }
        for i in range(len(stops) - 1)
    ]
    plan = {
        "id": str(plan_id or uuid.uuid4()).upper(),
        "date": 785_000_000.0,
        "title": "Saturday in the Village",
        "budget": 40,
        "stops": stops,
        "legs": legs,
        "extras": [],
    }
    plan.update(overrides)
    return plan


def today() -> date:
    """The plan's day is New York's (settings.TIME_ZONE), as the server checks it (N-8)."""
    return timezone.localdate()


def make_group(owner: Person, *members: Person, day=None, version=1, members_version=1, plan=None) -> GroupPlan:
    """A group straight in the database, with the organizer and `members` in it."""
    plan = plan or plan_json()
    group = GroupPlan.objects.create(
        owner=owner.profile,
        plan_id=uuid.UUID(plan["id"]),
        date=day or today() + timedelta(days=2),
        data=plan,
        version=version,
        members_version=members_version,
    )
    for who in (owner, *members):
        GroupMember.objects.create(group=group, profile=who.profile, display_name=who.profile.name.split()[0])
    return group


def etag(group: GroupPlan) -> str:
    group.refresh_from_db()
    return f'"{group.version}.{group.members_version}"'


def member_of(group: GroupPlan, who: Person) -> GroupMember:
    return GroupMember.objects.get(group=group, profile=who.profile)


# --- GS-1, RLS-1 to RLS-3, RLS-5: row level security on every new table, and no policies -----


@pytest.mark.parametrize("table", NEW_TABLES)
def test_rls_1_every_new_table_has_row_level_security(table):
    with connection.cursor() as cursor:
        cursor.execute("select relrowsecurity from pg_class where relname = %s", [table])
        assert cursor.fetchone() == (True,)


def test_rls_3_the_new_tables_have_no_policies():
    """RLS with no policies keeps Supabase's Data API roles out; a policy would let them in."""
    with connection.cursor() as cursor:
        cursor.execute("select tablename from pg_policies where tablename = any(%s)", [NEW_TABLES])
        assert cursor.fetchall() == []


def test_rls_5_a_role_without_bypassrls_sees_no_rows():
    """What Supabase's `authenticated` role would see through PostgREST: nothing, even with SELECT
    granted. Needs a database user that can create roles (the local and CI Postgres can)."""
    maya, jordan = person("Maya Lopez"), person("Jordan Lee")
    make_group(maya, jordan)
    with connection.cursor() as cursor:
        try:
            with transaction.atomic():
                cursor.execute("CREATE ROLE g3a_rls_probe NOLOGIN NOBYPASSRLS")
        except Exception:  # noqa: BLE001 - no CREATEROLE: nothing to check here
            pytest.skip("the test database user can't create roles")
        cursor.execute("GRANT USAGE ON SCHEMA public TO g3a_rls_probe")
        for table in NEW_TABLES:
            cursor.execute(f"GRANT SELECT ON {table} TO g3a_rls_probe")
        cursor.execute("SET LOCAL ROLE g3a_rls_probe")
        counts = {}
        for table in NEW_TABLES:
            cursor.execute(f"SELECT count(*) FROM {table}")
            counts[table] = cursor.fetchone()[0]
        cursor.execute("RESET ROLE")
    assert counts == dict.fromkeys(NEW_TABLES, 0)


# --- The database keeps the rules the API relies on -------------------------------------------


def test_one_group_per_plan_per_organizer():
    """N-9: a retried create finds the same group."""
    maya = person("Maya Lopez")
    group = make_group(maya)
    with pytest.raises(IntegrityError), transaction.atomic():
        GroupPlan.objects.create(owner=maya.profile, plan_id=group.plan_id, date=group.date, data=group.data)
    make_group(person("Jordan Lee"), plan=copy.deepcopy(group.data))  # another organizer: another group


def test_one_membership_per_person_per_group():
    maya = person("Maya Lopez")
    group = make_group(maya)
    with pytest.raises(IntegrityError), transaction.atomic():
        GroupMember.objects.create(group=group, profile=maya.profile, display_name="Maya")


@pytest.mark.parametrize("field", ["edit_id", "version"])
def test_each_edit_id_and_version_is_logged_once_per_group(field):
    """MF-B: an edit id answers for one version, and each version has one edit."""
    maya = person("Maya Lopez")
    group = make_group(maya)
    member_id = member_of(group, maya).id
    first = GroupPlanEdit.objects.create(
        group=group, version=2, edit_id=uuid.uuid4(), member_id=member_id, kind="remove", stop_ids=[new_id()]
    )
    other = {"edit_id": uuid.uuid4(), "version": 3, field: getattr(first, field)}
    with pytest.raises(IntegrityError), transaction.atomic():
        GroupPlanEdit.objects.create(group=group, member_id=member_id, kind="remove", stop_ids=[], **other)


def test_invite_tokens_are_22_url_safe_characters_and_differ():
    maya = person("Maya Lopez")
    tokens = {make_group(maya).invite_token for _ in range(5)}
    assert len(tokens) == 5
    for token in tokens:
        assert len(token) == 22
        assert set(token) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")


def test_the_edit_log_and_removals_hold_no_foreign_key_to_a_profile():
    """MF-E: nothing a group write inserts may wait on a profile's row when it commits."""
    for model in (GroupPlanEdit, GroupRemoval):
        related = [field.related_model for field in model._meta.concrete_fields if field.is_relation]
        assert related == [GroupPlan], model


# --- GS-5, CAS-6, CAS-7: group plans are deleted 30 days after their date ---------------------


def test_cas_7_group_plans_are_registered_for_expiry_30_days_after_their_date():
    rules = [rule for rule in retention.RULES if rule.model is GroupPlan]
    assert [(rule.date_field, rule.days) for rule in rules] == [("date", 30)]
    assert GROUP_RETENTION_DAYS == 30


def test_cas_6_purge_deletes_groups_at_30_days_with_everything_in_them_and_keeps_29():
    maya, jordan, riley = person("Maya Lopez"), person("Jordan Lee"), person("Riley Chen")
    expired = make_group(maya, jordan, day=today() - timedelta(days=30))
    kept = make_group(maya, jordan, day=today() - timedelta(days=29))
    for group in (expired, kept):
        GroupPlanEdit.objects.create(
            group=group, version=2, edit_id=uuid.uuid4(), member_id=member_of(group, jordan).id, kind="add"
        )
        GroupRemoval.objects.create(group=group, profile_id=riley.id)

    retention.purge_expired()

    assert list(GroupPlan.objects.all()) == [kept]
    assert set(GroupMember.objects.values_list("group_id", flat=True)) == {kept.id}
    assert set(GroupPlanEdit.objects.values_list("group_id", flat=True)) == {kept.id}
    assert set(GroupRemoval.objects.values_list("group_id", flat=True)) == {kept.id}


# --- Creating a group (brief GE-1; VER-1, INV-1, N-9, N-10) ----------------------------------

BASE = "/api/group-plans/"
TOKEN_PATTERN = r"[A-Za-z0-9_-]{22}"


def create(who: Person, plan=None, day=None, **extra):
    body = {"date": (day or today() + timedelta(days=2)).isoformat(), "plan": plan or plan_json(), **extra}
    return who.client.post(BASE, body, format="json")


def detail(group_id) -> str:
    return f"{BASE}{group_id}/"


def test_ver_1_inv_1_creating_returns_the_group_at_version_1_with_its_invite_link():
    maya = person("Maya Lopez")
    plan = plan_json()
    response = create(maya, plan)

    assert response.status_code == 201
    body = response.json()
    group = GroupPlan.objects.get()
    assert body["id"] == str(group.id)
    assert body["version"] == 1
    assert body["inviteUrl"] == f"http://testserver/j/{group.invite_token}"
    assert response["ETag"] == '"1.1"'
    assert response["Cache-Control"] == "private, no-cache"
    assert (group.owner_id, group.plan_id, group.data, group.version) == (maya.id, uuid.UUID(plan["id"]), plan, 1)
    # The organizer is a member, by their first name.
    assert body["members"] == [{"id": str(member_of(group, maya).id), "name": "Maya", "isOrganizer": True}]
    assert body["memberId"] == str(member_of(group, maya).id)
    assert body["isOrganizer"] is True
    assert body["plan"] == plan


def test_inv_1_invite_links_use_the_invite_base_url_and_differ_between_groups(settings):
    import re

    settings.INVITE_BASE_URL = "https://plandit.app/"
    maya = person("Maya Lopez")
    urls = [create(maya).json()["inviteUrl"] for _ in range(2)]
    for url in urls:
        assert re.fullmatch(rf"https://plandit\.app/j/{TOKEN_PATTERN}", url), url
    assert urls[0] != urls[1]


def test_invite_links_stay_on_this_host_when_only_share_and_request_links_move(settings):
    settings.SHARE_BASE_URL = "https://plandit.app"
    settings.REQUEST_BASE_URL = "https://plandit.app"
    assert create(person("Maya Lopez")).json()["inviteUrl"].startswith("http://testserver/j/")


def test_con_11_creating_again_from_the_same_plan_returns_the_same_group_unchanged():
    """N-9: a double tap or a retry after a lost response makes one group and one link."""
    maya = person("Maya Lopez")
    plan = plan_json()
    first = create(maya, plan)
    again = create(maya, plan_json(plan["id"], title="Changed"))

    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json()["id"] == first.json()["id"]
    assert again.json()["inviteUrl"] == first.json()["inviteUrl"]
    assert GroupPlan.objects.count() == 1
    assert GroupPlan.objects.get().data == plan
    assert GroupMember.objects.count() == 1


def test_creating_needs_an_account():
    assert create(Person(None, anonymous_client())).status_code == 401
    assert GroupPlan.objects.count() == 0


def test_iso_6_an_anonymous_session_cannot_create_a_group():
    """N-10: old TestFlight builds signed in anonymously; a group needs a name to show."""
    response = create(person("", is_anonymous=True))
    assert response.status_code == 403
    assert response.json() == {"detail": "Sign in with email or Apple to plan with friends."}
    assert GroupPlan.objects.count() == 0


@pytest.mark.parametrize(
    ("name", "shown"),
    [
        ("Maya Lopez", "Maya"),
        ("  Jordan   Lee ", "Jordan"),
        ("Mary-Ann O'Neil", "Mary-Ann"),
        ("", "Friend"),
        ("    ", "Friend"),
        ("🎉 Party", "Friend"),
        ("J. Lee", "Friend"),
        ("A" * 120, "A" * 30),
    ],
)
def test_inv_4_the_display_name_is_the_first_word_of_the_profile_name_or_friend(name, shown):
    """N-10: never empty, at most 30 characters, and only what a friend's first name may be."""
    who = person(name)
    body = create(who).json()
    assert body["members"][0]["name"] == shown
    assert GroupMember.objects.get().display_name == shown


# --- LIM-2 to LIM-8: what a plan may be, for create and for PUT ------------------------------


def sized_plan(size: int, plan_id=None) -> dict:
    """A plan whose compact UTF-8 JSON is exactly `size` bytes, as the server measures it."""
    import json

    plan = plan_json(plan_id, title="")
    base = len(json.dumps(plan, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    plan["title"] = "é" * ((size - base) // 2) + "x" * ((size - base) % 2)
    assert len(json.dumps(plan, separators=(",", ":"), ensure_ascii=False).encode("utf-8")) == size
    return plan


def test_lim_2_create_accepts_a_plan_of_exactly_64_kb_and_refuses_one_byte_more():
    maya = person("Maya Lopez")
    assert create(maya, sized_plan(65_536)).status_code == 201
    response = create(maya, sized_plan(65_537))
    assert response.status_code == 413
    assert GroupPlan.objects.count() == 1


def test_lim_3_create_refuses_a_declared_oversize_body_before_reading_it():
    maya = person("Maya Lopez")
    response = maya.client.post(
        BASE, data=b'{"date": "2026-01-01", "plan": {}}', content_type="application/json", CONTENT_LENGTH="400000"
    )
    assert response.status_code == 413
    assert GroupPlan.objects.count() == 0


def test_lim_4_create_accepts_20_stops_and_refuses_21():
    maya = person("Maya Lopez")
    assert create(maya, plan_json(stops=[stop_json() for _ in range(20)])).status_code == 201
    response = create(maya, plan_json(stops=[stop_json() for _ in range(21)]))
    assert response.status_code == 400
    assert response.json() == {"plan": ["A group plan has at most 20 stops."]}


def bad_plans():
    stop = stop_json()
    duplicate = {**stop_json(), "id": stop["id"].lower()}
    without = {k: v for k, v in stop_json().items() if k != "id"}
    return {
        "not an object": [plan_json()],
        "no id": {k: v for k, v in plan_json().items() if k != "id"},
        "id not a UUID": plan_json(id="plan-1"),
        "stops not a list": plan_json(stops={"a": stop}),
        "a stop not an object": plan_json(stops=["The Met"]),
        "a stop without an id": plan_json(stops=[without]),
        "a stop id not a UUID": plan_json(stops=[{**stop, "id": 7}]),
        "duplicate stop ids": plan_json(stops=[stop, duplicate]),
        "no legs": {k: v for k, v in plan_json().items() if k != "legs"},
        "legs not a list": plan_json(legs=None),
        "no date": {k: v for k, v in plan_json().items() if k != "date"},
        "null date": plan_json(date=None),
        "no title": {k: v for k, v in plan_json().items() if k != "title"},
        "title not text": plan_json(title=3),
        "no budget": {k: v for k, v in plan_json().items() if k != "budget"},
        "budget not a number": plan_json(budget="40"),
        "budget a bool": plan_json(budget=True),
        "a null character": plan_json(title="Sat\x00urday"),
    }


@pytest.mark.parametrize("case", list(bad_plans()))
def test_lim_5_create_refuses_a_plan_of_the_wrong_shape(case):
    """N-4: one member's bad plan would break decoding on every member's phone."""
    response = create(person("Maya Lopez"), bad_plans()[case])
    assert response.status_code == 400
    assert "plan" in response.json()
    assert GroupPlan.objects.count() == 0


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity"])
def test_lim_7_create_refuses_nan_and_infinity(constant):
    maya = person("Maya Lopez")
    raw = f'{{"date": "{(today() + timedelta(days=1)).isoformat()}", "plan": {{"budget": {constant}}}}}'
    response = maya.client.post(BASE, data=raw, content_type="application/json")
    assert response.status_code == 400
    assert GroupPlan.objects.count() == 0


@pytest.mark.parametrize(
    "value",
    [
        (date.today() - timedelta(days=400)).isoformat(),
        "yesterday",
        "2026-13-01",
        "2026-11-22T10:00:00",
        "20261122",
        None,
        20261122,
    ],
)
def test_lim_8_create_refuses_a_bad_date(value):
    maya = person("Maya Lopez")
    response = maya.client.post(BASE, {"date": value, "plan": plan_json()}, format="json")
    assert response.status_code == 400
    assert "date" in response.json()


def test_lim_8_the_date_is_today_to_366_days_ahead_in_new_york_time():
    maya = person("Maya Lopez")
    assert create(maya, day=today() - timedelta(days=1)).status_code == 400
    assert create(maya, day=today() + timedelta(days=367)).status_code == 400
    assert create(maya, day=today()).status_code == 201
    assert create(maya, day=today() + timedelta(days=366)).status_code == 201


def test_create_refuses_a_body_that_is_not_an_object():
    maya = person("Maya Lopez")
    assert maya.client.post(BASE, [plan_json()], format="json").status_code == 400


def test_lim_9_a_plan_with_unicode_names_round_trips_unchanged():
    maya = person("Maya Lopez")
    plan = plan_json(title="Sábado en el Village ☕️", stops=[stop_json(name="Café Lalo"), stop_json(name="喜茶")])
    group_id = create(maya, plan).json()["id"]
    assert maya.client.get(detail(group_id)).json()["plan"] == plan


def test_ver_12_creating_a_group_never_touches_the_callers_snapshot():
    maya = person("Maya Lopez")
    snapshot = {"data": {"today": plan_json(), "saved": [], "pastPlans": []}}
    assert maya.client.put("/api/me/snapshot/", snapshot, format="json").json()["version"] == 1
    assert create(maya).status_code == 201
    body = maya.client.get("/api/me/snapshot/").json()
    assert (body["version"], body["data"]) == (1, snapshot["data"])


# --- Reading a group: GET with its ETag (brief GE-4; VER-6, VER-7, VER-8, VER-13, ISO-3) -----


@pytest.fixture
def maya():
    return person("Maya Lopez")


@pytest.fixture
def jordan():
    return person("Jordan Lee")


@pytest.fixture
def group(maya, jordan):
    return make_group(maya, jordan, version=3, members_version=2)


def test_a_member_reads_the_plan_and_the_members(group, maya, jordan):
    response = jordan.client.get(detail(group.id))

    assert response.status_code == 200
    assert response["ETag"] == '"3.2"'
    assert response["Cache-Control"] == "private, no-cache"
    body = response.json()
    assert body == {
        "id": str(group.id),
        "date": group.date.isoformat(),
        "version": 3,
        "membersVersion": 2,
        "plan": group.data,
        "members": [
            {"id": str(member_of(group, maya).id), "name": "Maya", "isOrganizer": True},
            {"id": str(member_of(group, jordan).id), "name": "Jordan", "isOrganizer": False},
        ],
        "memberId": str(member_of(group, jordan).id),
        "isOrganizer": False,
        "inviteUrl": None,
    }


def test_only_the_organizer_reads_the_invite_link(group, maya):
    body = maya.client.get(detail(group.id)).json()
    assert body["inviteUrl"] == f"http://testserver/j/{group.invite_token}"
    assert body["isOrganizer"] is True


@pytest.mark.parametrize("header", ['"3.2"', 'W/"3.2"', '"x", "3.2"', '"1.1", W/"3.2"', "*"])
def test_ver_6_a_matching_if_none_match_is_304_with_its_headers_and_no_body(group, jordan, header):
    response = jordan.client.get(detail(group.id), HTTP_IF_NONE_MATCH=header)
    assert response.status_code == 304
    assert response.content == b""
    assert response["ETag"] == '"3.2"'
    assert response["Cache-Control"] == "private, no-cache"


@pytest.mark.parametrize("header", ['"2.2"', '"3.1"', '"3"', "3.2", "garbage", '"3.2', ""])
def test_ver_6_any_other_if_none_match_is_200(group, jordan, header):
    response = jordan.client.get(detail(group.id), HTTP_IF_NONE_MATCH=header)
    assert response.status_code == 200
    assert response.json()["version"] == 3


def test_ver_7_a_200_is_private_and_revalidated(group, jordan):
    assert jordan.client.get(detail(group.id))["Cache-Control"] == "private, no-cache"


def test_ver_13_a_304_poll_costs_at_most_3_queries_and_never_purges(
    group, jordan, monkeypatch, django_assert_max_num_queries
):
    def no_purge(*args, **kwargs):
        raise AssertionError("a poll ran the retention purge")

    monkeypatch.setattr(retention.ExpiryRule, "purge", no_purge)
    assert jordan.client.get(detail(group.id)).status_code == 200  # records today's activity
    with django_assert_max_num_queries(3):
        assert jordan.client.get(detail(group.id), HTTP_IF_NONE_MATCH='"3.2"').status_code == 304
    with django_assert_max_num_queries(3):
        assert jordan.client.get(detail(group.id)).status_code == 200


@pytest.mark.parametrize("case", ["upper", "lower"])
def test_iso_3_the_group_id_may_come_in_either_case(group, jordan, case):
    """The app sends Swift UUIDs, which are upper case (G1a's must-fix, 04-progress.md:47)."""
    group_id = str(group.id).upper() if case == "upper" else str(group.id)
    assert jordan.client.get(detail(group_id)).status_code == 200


@pytest.mark.parametrize("group_id", ["not-a-uuid", "1234", "%20", "6f1c2d3e-4a5b-4c6d-8e7f-901a2b3c4d5", "x" * 200])
def test_iso_3_a_malformed_id_is_404_not_500(group, jordan, group_id):
    assert jordan.client.get(detail(group_id)).status_code == 404


def test_cas_8_members_still_read_the_plan_after_its_day_until_it_expires(maya, jordan):
    """GE-9: each phone moves the plan to Past plans after the day, so it must still be readable."""
    group = make_group(maya, jordan, day=today() - timedelta(days=1))
    assert jordan.client.get(detail(group.id)).status_code == 200
    old = make_group(maya, jordan, day=today() - timedelta(days=29))
    assert jordan.client.get(detail(old.id)).status_code == 200


# --- Listing the caller's groups ---------------------------------------------------------------


def test_the_list_has_the_callers_groups_with_their_etags(maya, jordan):
    sam = person("Sam Rivera")
    later = make_group(maya, jordan, day=today() + timedelta(days=5), version=4, members_version=2)
    sooner = make_group(sam, jordan, day=today() + timedelta(days=1))
    make_group(sam)  # Jordan isn't in this one

    response = jordan.client.get(BASE)
    assert response.status_code == 200
    assert response.json() == {
        "groups": [
            {
                "id": str(sooner.id),
                "date": sooner.date.isoformat(),
                "version": 1,
                "membersVersion": 1,
                "etag": '"1.1"',
                "organizerName": "Sam",
                "memberCount": 2,
                "memberId": str(member_of(sooner, jordan).id),
                "isOrganizer": False,
                "inviteUrl": None,
            },
            {
                "id": str(later.id),
                "date": later.date.isoformat(),
                "version": 4,
                "membersVersion": 2,
                "etag": '"4.2"',
                "organizerName": "Maya",
                "memberCount": 2,
                "memberId": str(member_of(later, jordan).id),
                "isOrganizer": False,
                "inviteUrl": None,
            },
        ]
    }
    organizer_view = maya.client.get(BASE).json()["groups"]
    assert [(g["id"], g["isOrganizer"], g["inviteUrl"]) for g in organizer_view] == [
        (str(later.id), True, f"http://testserver/j/{later.invite_token}")
    ]


def test_the_list_is_empty_for_someone_in_no_group(group):
    assert person("Sam Rivera").client.get(BASE).json() == {"groups": []}
