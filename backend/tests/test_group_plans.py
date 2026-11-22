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


# --- Editing: PUT with compare-and-swap and the edit log (brief GE-5; VER-2 to VER-5, VER-9 to
# --- VER-12, LIM-2 to LIM-7, N-8) -------------------------------------------------------------


def edited(group: GroupPlan) -> dict:
    """The group's plan with its last stop removed, as the app would PUT it."""
    group.refresh_from_db()
    plan = copy.deepcopy(group.data)
    plan["stops"] = plan["stops"][:-1]
    plan["legs"] = []
    return plan


CURRENT = object()


def put(who: Person, group: GroupPlan, plan=None, *, base=CURRENT, edit_id=None, kind="remove", stop_ids=None, **extra):
    """PUT `plan` (by default the group's plan less its last stop) from the group's current version,
    or from `base`. The edit names the stops the plan no longer has, unless `stop_ids` is given."""
    group.refresh_from_db()
    plan = plan if plan is not None else edited(group)
    if stop_ids is None:
        kept = {stop["id"] for stop in plan["stops"]}
        stop_ids = [stop["id"] for stop in group.data["stops"] if stop["id"] not in kept]
    body = {
        "baseVersion": group.version if base is CURRENT else base,
        "editId": edit_id or new_id(),
        "edit": {"kind": kind, "stopIds": stop_ids},
        "plan": plan,
        **extra,
    }
    return who.client.put(detail(group.id), body, format="json")


def row(group: GroupPlan) -> tuple:
    """Everything a refused write must leave as it was."""
    fresh = GroupPlan.objects.get(pk=group.pk)
    return (fresh.data, fresh.version, fresh.members_version, fresh.updated_at, fresh.invite_token)


def test_ver_2_a_put_from_the_current_version_stores_the_plan_and_logs_the_edit(group, maya, jordan):
    plan = edited(group)
    stop_id = group.data["stops"][-1]["id"]
    edit_id = new_id()
    response = put(jordan, group, plan, edit_id=edit_id)

    assert response.status_code == 200
    assert response["ETag"] == '"4.2"'
    assert response["Cache-Control"] == "private, no-cache"
    assert response.json() == {
        "version": 4,
        "membersVersion": 2,
        "members": [
            {"id": str(member_of(group, maya).id), "name": "Maya", "isOrganizer": True},
            {"id": str(member_of(group, jordan).id), "name": "Jordan", "isOrganizer": False},
        ],
    }
    group.refresh_from_db()
    assert (group.data, group.version, group.members_version) == (plan, 4, 2)
    logged = GroupPlanEdit.objects.get()
    assert (logged.version, logged.edit_id, logged.member_id, logged.kind, logged.stop_ids) == (
        4,
        uuid.UUID(edit_id),
        member_of(group, jordan).id,
        "remove",
        [stop_id],
    )


def test_ver_3_a_put_from_an_old_version_is_409_with_the_plan_the_members_and_the_edits_since(group, maya, jordan):
    first = put(maya, group, kind="move")
    assert first.status_code == 200
    before = row(group)

    response = put(jordan, group, base=3)
    assert response.status_code == 409
    assert response["ETag"] == '"4.2"'
    assert response["Cache-Control"] == "private, no-cache"
    body = response.json()
    assert set(body) == {"version", "membersVersion", "plan", "members", "edits"}
    assert (body["version"], body["membersVersion"], body["plan"]) == (4, 2, before[0])
    assert [m["name"] for m in body["members"]] == ["Maya", "Jordan"]
    stop_ids = GroupPlanEdit.objects.get().stop_ids
    maya_member = str(member_of(group, maya).id)
    assert body["edits"] == [
        {"version": 4, "authorId": maya_member, "authorName": "Maya", "kind": "move", "stopIds": stop_ids}
    ]
    assert row(group) == before
    assert GroupPlanEdit.objects.count() == 1


def test_ver_4_a_put_from_a_version_ahead_of_the_server_is_409_never_200(group, jordan):
    before = row(group)
    response = put(jordan, group, base=4)
    assert response.status_code == 409
    assert response.json()["edits"] == []
    assert row(group) == before


@pytest.mark.parametrize("base", ["missing", None, "3", True, 3.0, -1, 0, [3], {"v": 3}])
def test_ver_5_a_base_version_that_isnt_a_whole_number_is_400(group, jordan, base):
    """A bool must not count as an int (as core/views.py's `_is_positive_int`)."""
    before = row(group)
    response = put(jordan, group, base=base)
    if base == "missing":
        body = {"editId": new_id(), "edit": {"kind": "remove", "stopIds": []}, "plan": edited(group)}
        response = jordan.client.put(detail(group.id), body, format="json")
    assert response.status_code == 400
    assert "baseVersion" in response.json()
    assert row(group) == before


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("editId", None),
        ("editId", "edit-1"),
        ("editId", 7),
        ("edit", None),
        ("edit", "remove"),
        ("edit", {"stopIds": []}),
        ("edit", {"kind": "", "stopIds": []}),
        ("edit", {"kind": "remove the stop", "stopIds": []}),
        ("edit", {"kind": "x" * 17, "stopIds": []}),
        ("edit", {"kind": "remove"}),
        ("edit", {"kind": "remove", "stopIds": "abc"}),
        ("edit", {"kind": "remove", "stopIds": ["not-a-uuid"]}),
        ("edit", {"kind": "remove", "stopIds": [str(uuid.uuid4()) for _ in range(21)]}),
    ],
)
def test_a_put_without_a_valid_edit_id_or_edit_is_400(group, jordan, field, value):
    before = row(group)
    response = put(jordan, group, **{field: value})
    assert response.status_code == 400
    assert field in response.json()
    assert row(group) == before


def test_a_put_body_that_is_not_an_object_is_400(group, jordan):
    assert jordan.client.put(detail(group.id), [edited(group)], format="json").status_code == 400


def test_ver_9_five_puts_in_a_row_make_versions_4_to_8_without_gaps(group, maya, jordan):
    versions = []
    for who in (maya, jordan, maya, jordan, maya):
        response = put(who, group)
        assert response.status_code == 200
        versions.append(response.json()["version"])
    assert versions == [4, 5, 6, 7, 8]
    assert list(GroupPlanEdit.objects.order_by("version").values_list("version", flat=True)) == versions


def test_ver_10_a_retried_edit_answers_with_its_version_and_changes_nothing(group, maya, jordan):
    """MF-B: the response to the first PUT was lost; the app sends it again, same editId and base."""
    edit_id = new_id()
    plan = edited(group)
    first = put(jordan, group, plan, edit_id=edit_id)
    assert first.status_code == 200
    put(maya, group)  # someone else edits meanwhile: version 5
    before = row(group)

    again = put(jordan, group, plan, edit_id=edit_id.lower(), base=3)
    assert again.status_code == 200
    assert again.json()["version"] == 4
    assert again["ETag"] == '"4.2"'
    assert row(group) == before
    assert GroupPlanEdit.objects.count() == 2

    other = put(jordan, group, plan, base=3)
    assert other.status_code == 409
    assert row(group) == before


def test_ver_11_the_409_names_who_made_each_edit_since_the_base(maya, jordan):
    """MF-C: A removes s2 at v2, B changes s1's time at v3, C sends a PUT from v1."""
    casey = person("Casey Kim")
    group = make_group(maya, jordan, casey)
    s1, s2 = (stop["id"] for stop in group.data["stops"])
    plan = edited(group)
    assert put(maya, group, plan, kind="remove", stop_ids=[s2]).status_code == 200
    plan = copy.deepcopy(plan)
    plan["stops"][0]["start"] += 1800
    assert put(jordan, group, plan, kind="setTime", stop_ids=[s1]).status_code == 200

    response = put(casey, group, base=1)
    assert response.status_code == 409
    assert [(e["version"], e["authorName"], e["kind"], e["stopIds"]) for e in response.json()["edits"]] == [
        (2, "Maya", "remove", [s2]),
        (3, "Jordan", "setTime", [s1]),
    ]


def test_the_log_keeps_the_latest_edits_only(group, maya, monkeypatch):
    from plandit.groups import views

    monkeypatch.setattr(views, "EDIT_LOG_KEPT", 3)
    for _ in range(5):
        assert put(maya, group).status_code == 200
    assert list(GroupPlanEdit.objects.order_by("version").values_list("version", flat=True)) == [6, 7, 8]


def test_lim_6_a_put_of_another_plan_is_400(group, jordan):
    """GE-6: catches the app writing the member's personal plan into the group."""
    before = row(group)
    response = put(jordan, group, plan_json())
    assert response.status_code == 400
    assert "plan" in response.json()
    assert row(group) == before


def test_lim_2_a_put_accepts_a_plan_of_exactly_64_kb_and_refuses_one_byte_more(group, jordan):
    plan_id = group.data["id"]
    assert put(jordan, group, sized_plan(65_536, plan_id)).status_code == 200
    before = row(group)
    response = put(jordan, group, sized_plan(65_537, plan_id))
    assert response.status_code == 413
    assert row(group) == before


def test_lim_3_a_put_refuses_a_declared_oversize_body_before_reading_it(group, jordan):
    response = jordan.client.put(
        detail(group.id), data=b'{"baseVersion": 3}', content_type="application/json", CONTENT_LENGTH="400000"
    )
    assert response.status_code == 413


def test_lim_4_a_put_accepts_20_stops_and_refuses_21(group, jordan):
    plan_id = group.data["id"]
    assert put(jordan, group, plan_json(plan_id, stops=[stop_json() for _ in range(20)])).status_code == 200
    before = row(group)
    response = put(jordan, group, plan_json(plan_id, stops=[stop_json() for _ in range(21)]))
    assert response.status_code == 400
    assert row(group) == before


@pytest.mark.parametrize("case", list(bad_plans()))
def test_lim_5_a_put_of_a_plan_of_the_wrong_shape_is_400(group, jordan, case):
    plan = bad_plans()[case]
    if isinstance(plan, dict) and "id" in plan and case != "id not a UUID":
        plan["id"] = group.data["id"]
    before = row(group)
    response = put(jordan, group, plan, stop_ids=[])
    assert response.status_code == 400
    assert row(group) == before


def test_lim_7_a_put_with_nan_is_400(group, jordan):
    raw = (
        f'{{"baseVersion": 3, "editId": "{new_id()}", "edit": {{"kind": "remove", "stopIds": []}}, '
        f'"plan": {{"id": "{group.data["id"]}", "budget": NaN}}}}'
    )
    response = jordan.client.put(detail(group.id), data=raw, content_type="application/json")
    assert response.status_code == 400


def test_n_8_edits_end_with_the_plans_day_in_new_york_time(maya, jordan):
    over = make_group(maya, jordan, day=today() - timedelta(days=1))
    before = row(over)
    response = put(jordan, over)
    assert response.status_code == 400
    assert response.json() == {"detail": "This plan's day is over."}
    assert row(over) == before

    on_the_day = make_group(person("Sam Rivera"), jordan, day=today())
    assert put(jordan, on_the_day).status_code == 200


def test_ver_12_a_put_never_touches_the_callers_snapshot(group, jordan):
    snapshot = {"data": {"today": plan_json(), "saved": [], "pastPlans": []}}
    assert jordan.client.put("/api/me/snapshot/", snapshot, format="json").json()["version"] == 1
    assert put(jordan, group).status_code == 200
    body = jordan.client.get("/api/me/snapshot/").json()
    assert (body["version"], body["data"]) == (1, snapshot["data"])


def test_iso_2_an_outsider_cannot_tell_a_group_from_a_random_id(group):
    """Same status and body, and no ETag, for a group that exists and one that doesn't."""
    sam = person("Sam Rivera")
    random_id = uuid.uuid4()
    gets = [sam.client.get(detail(gid), HTTP_IF_NONE_MATCH='"3.2"') for gid in (group.id, random_id)]
    body = {"baseVersion": 1, "editId": new_id(), "edit": {"kind": "remove", "stopIds": []}, "plan": edited(group)}
    puts = [sam.client.put(detail(gid), body, format="json") for gid in (group.id, random_id)]
    bad_puts = [sam.client.put(detail(gid), {"plan": 3}, format="json") for gid in (group.id, random_id)]
    for pair in (gets, puts, bad_puts):
        assert [r.status_code for r in pair] == [404, 404]
        assert pair[0].content == pair[1].content == b""
        assert not pair[0].has_header("ETag") and not pair[1].has_header("ETag")


# --- Invites: preview, join and a new link (brief GE-1, GE-2, GE-8; INV-2 to INV-9, INV-14,
# --- LIM-1, VER-8, MF-G) ----------------------------------------------------------------------


def preview_path(token: str) -> str:
    return f"{BASE}invites/{token}/"


def join_path(token: str) -> str:
    return f"{BASE}invites/{token}/join"


def invite_path(group) -> str:
    return f"{BASE}{group.id}/invite"


def token_of(group: GroupPlan) -> str:
    group.refresh_from_db()
    return group.invite_token


def join(who: Person, group: GroupPlan, token=None):
    return who.client.post(join_path(token or token_of(group)))


def test_inv_2_the_preview_shows_only_the_organizers_first_name_the_date_and_the_member_count(group):
    sam = person("Sam Rivera")
    response = sam.client.get(preview_path(token_of(group)))
    assert response.status_code == 200
    assert response.json() == {"organizerName": "Maya", "date": group.date.isoformat(), "memberCount": 2}
    assert response["Cache-Control"] == "private, no-cache"


def test_inv_3_joining_adds_the_member_by_first_name_and_they_can_read_the_plan(group, maya, jordan):
    sam = person("Sam Rivera")
    response = join(sam, group)

    assert response.status_code == 200
    member = member_of(group, sam)
    assert member.display_name == "Sam"
    group.refresh_from_db()
    assert (group.version, group.members_version) == (3, 3)
    assert response["ETag"] == '"3.3"'
    body = response.json()
    assert (body["id"], body["memberId"], body["isOrganizer"], body["inviteUrl"]) == (
        str(group.id),
        str(member.id),
        False,
        None,
    )
    assert [m["name"] for m in body["members"]] == ["Maya", "Jordan", "Sam"]
    assert sam.client.get(detail(group.id)).status_code == 200
    assert [g["id"] for g in sam.client.get(BASE).json()["groups"]] == [str(group.id)]


def test_inv_4_a_joiner_without_a_usable_name_shows_as_friend(group):
    sam = person("🎉")
    assert join(sam, group).status_code == 200
    assert member_of(group, sam).display_name == "Friend"


def test_inv_5_joining_twice_changes_nothing(group):
    sam = person("Sam Rivera")
    assert join(sam, group).status_code == 200
    before = row(group)
    again = join(sam, group)
    assert again.status_code == 200
    assert again.json()["memberId"] == str(member_of(group, sam).id)
    assert GroupMember.objects.filter(group=group, profile=sam.profile).count() == 1
    assert row(group) == before


def full_group(maya, jordan) -> GroupPlan:
    others = [person(f"Friend{i} Lee") for i in range(6)]
    group = make_group(maya, jordan, *others)
    assert group.members.count() == 8
    return group


def test_inv_5_a_member_of_a_full_group_can_still_open_its_link(maya, jordan):
    group = full_group(maya, jordan)
    assert jordan.client.get(preview_path(token_of(group))).status_code == 200
    assert join(jordan, group).status_code == 200
    assert group.members.count() == 8


def test_inv_6_the_organizer_opening_their_own_link_changes_nothing(group, maya):
    before = row(group)
    assert maya.client.get(preview_path(token_of(group))).status_code == 200
    response = join(maya, group)
    assert response.status_code == 200
    assert response.json()["isOrganizer"] is True
    assert row(group) == before


def test_lim_1_inv_8_a_ninth_member_cannot_preview_or_join(maya, jordan):
    group = full_group(maya, jordan)
    before = row(group)
    sam = person("Sam Rivera")
    assert sam.client.get(preview_path(token_of(group))).status_code == 404
    response = join(sam, group)
    assert response.status_code == 404
    assert response.content == b""
    assert group.members.count() == 8
    assert row(group) == before


def test_inv_7_only_the_latest_link_works_after_replacing_it_twice(group, maya, jordan):
    first = token_of(group)
    second_url = maya.client.post(invite_path(group)).json()["inviteUrl"]
    second = token_of(group)
    response = maya.client.post(invite_path(group))
    assert response.status_code == 200
    third = token_of(group)
    assert response.json() == {"inviteUrl": f"http://testserver/j/{third}"}
    assert second_url == f"http://testserver/j/{second}"
    assert len({first, second, third}) == 3

    sam = person("Sam Rivera")
    for old in (first, second):
        assert sam.client.get(preview_path(old)).status_code == 404
        assert sam.client.post(join_path(old)).status_code == 404
    assert not GroupMember.objects.filter(profile=sam.profile).exists()
    assert sam.client.get(preview_path(third)).status_code == 200
    assert sam.client.post(join_path(third)).status_code == 200
    assert [m.display_name for m in group.members.order_by("joined_at")] == ["Maya", "Jordan", "Sam"]


def test_inv_7_only_the_organizer_replaces_the_link(group, jordan):
    before = row(group)
    assert jordan.client.post(invite_path(group)).status_code == 404
    assert person("Sam Rivera").client.post(invite_path(group)).status_code == 404
    assert row(group) == before


def test_inv_9_mf_g_someone_the_organizer_removed_cannot_rejoin_with_the_link(group):
    riley = person("Riley Park")
    GroupRemoval.objects.create(group=group, profile_id=riley.id)
    assert riley.client.get(preview_path(token_of(group))).status_code == 404
    assert join(riley, group).status_code == 404
    assert not GroupMember.objects.filter(profile=riley.profile).exists()


def test_inv_14_a_group_past_its_day_cannot_be_previewed_or_joined(maya, jordan):
    over = make_group(maya, jordan, day=today() - timedelta(days=1))
    sam = person("Sam Rivera")
    assert sam.client.get(preview_path(token_of(over))).status_code == 404
    assert join(sam, over).status_code == 404
    on_the_day = make_group(person("Ana Cruz"), day=today())
    assert sam.client.get(preview_path(token_of(on_the_day))).status_code == 200
    assert join(sam, on_the_day).status_code == 200


@pytest.mark.parametrize(
    "token",
    ["fake-invite-token", "fake-invite-token-for-tests", "fake.invite.token.for.t", "x" * 200, "%20"],
)
def test_a_malformed_or_unknown_token_is_404(group, token):
    sam = person("Sam Rivera")
    assert sam.client.get(preview_path(token)).status_code == 404
    assert sam.client.post(join_path(token)).status_code == 404


def test_iso_6_an_anonymous_session_can_preview_but_not_join(group):
    """N-10: joining needs a name to show; the preview shows nothing about the caller."""
    anon = person("", is_anonymous=True)
    assert anon.client.get(preview_path(token_of(group))).status_code == 200
    response = join(anon, group)
    assert response.status_code == 403
    assert response.json() == {"detail": "Sign in with email or Apple to plan with friends."}
    assert not GroupMember.objects.filter(profile=anon.profile).exists()


def test_invites_need_an_account(group):
    for client in (anonymous_client(), deleted_client()):
        assert client.get(preview_path(token_of(group))).status_code == 401
        assert client.post(join_path(token_of(group))).status_code == 401
        assert client.post(invite_path(group)).status_code == 401


def test_ver_8_the_etag_changes_when_someone_joins(group, jordan):
    old = jordan.client.get(detail(group.id))["ETag"]
    assert join(person("Sam Rivera"), group).status_code == 200
    response = jordan.client.get(detail(group.id), HTTP_IF_NONE_MATCH=old)
    assert response.status_code == 200
    assert [m["name"] for m in response.json()["members"]] == ["Maya", "Jordan", "Sam"]


@pytest.mark.parametrize("path", ["{base}invites/{token}/join/", "{base}{id}/invite/"])
def test_ctr_1_post_paths_work_with_a_trailing_slash_too(group, maya, path):
    """POST can't follow APPEND_SLASH's redirect, so both spellings answer (never 301)."""
    url = path.format(base=BASE, token=token_of(group), id=group.id)
    assert maya.client.post(url).status_code == 200


# --- Leaving, removing and ending (brief GE-7; ISO-4, ISO-5, CAS-4, CAS-5, VER-8, N-8b, N-12,
# --- MF-G) ------------------------------------------------------------------------------------


def member_path(group, member_or_id) -> str:
    member_id = member_or_id.id if isinstance(member_or_id, GroupMember) else member_or_id
    return f"{BASE}{group.id}/members/{member_id}/"


def test_the_organizer_removes_a_member_who_then_cannot_rejoin(group, maya, jordan):
    """GE-7 and MF-G: the removal is kept, so the same link no longer works for them."""
    before_etag = etag(group)
    response = maya.client.delete(member_path(group, member_of(group, jordan)))

    assert response.status_code == 204
    assert not GroupMember.objects.filter(group=group, profile=jordan.profile).exists()
    assert GroupRemoval.objects.filter(group=group, profile_id=jordan.id).count() == 1
    group.refresh_from_db()
    assert (group.version, group.members_version) == (3, 3)
    assert etag(group) != before_etag
    assert jordan.client.get(preview_path(token_of(group))).status_code == 404
    assert join(jordan, group).status_code == 404


def test_iso_5_a_removed_member_gets_404_for_their_last_etag_and_their_put(group, maya, jordan):
    held = jordan.client.get(detail(group.id))["ETag"]
    base = group.version
    assert maya.client.delete(member_path(group, member_of(group, jordan))).status_code == 204
    before = row(group)

    response = jordan.client.get(detail(group.id), HTTP_IF_NONE_MATCH=held)
    assert response.status_code == 404
    assert not response.has_header("ETag")
    assert put(jordan, group, base=base).status_code == 404
    assert row(group) == before
    assert jordan.client.get(BASE).json() == {"groups": []}


def test_cas_5_a_member_leaves_and_can_come_back_with_the_link(group, maya, jordan):
    """Leaving yourself writes no removal (MF-G)."""
    response = jordan.client.delete(member_path(group, member_of(group, jordan)))
    assert response.status_code == 204
    assert not GroupRemoval.objects.exists()
    organizer_view = maya.client.get(detail(group.id)).json()
    assert [m["name"] for m in organizer_view["members"]] == ["Maya"]
    assert organizer_view["membersVersion"] == 3
    assert jordan.client.get(detail(group.id)).status_code == 404

    assert jordan.client.delete(member_path(group, uuid.uuid4())).status_code == 404
    assert join(jordan, group).status_code == 200


def test_cas_5_leaving_twice_is_404_the_second_time(group, jordan):
    path = member_path(group, member_of(group, jordan))
    assert jordan.client.delete(path).status_code == 204
    assert jordan.client.delete(path).status_code == 404


def test_n_8b_the_organizer_cannot_leave_their_own_plan(group, maya):
    before = row(group)
    response = maya.client.delete(member_path(group, member_of(group, maya)))
    assert response.status_code == 400
    assert response.json() == {"detail": "Organizers can't leave their own plan. End the plan instead."}
    assert row(group) == before
    assert group.members.count() == 2


def test_a_member_cannot_remove_someone_else(group, maya, jordan):
    casey = person("Casey Kim")
    GroupMember.objects.create(group=group, profile=casey.profile, display_name="Casey")
    before = row(group)
    assert jordan.client.delete(member_path(group, member_of(group, casey))).status_code == 404
    assert jordan.client.delete(member_path(group, member_of(group, maya))).status_code == 404
    assert group.members.count() == 3
    assert row(group) == before


def test_iso_4_an_organizer_cannot_remove_a_member_of_another_group(group, maya):
    """The member id must belong to this group; a profile id never addresses anyone (N-11)."""
    sam = person("Sam Rivera")
    avery = person("Avery Diaz")
    other = make_group(sam, avery)
    for target in (member_of(other, avery), avery.id, member_of(other, sam)):
        assert maya.client.delete(member_path(group, target)).status_code == 404
    assert other.members.count() == 2
    assert maya.client.delete(member_path(other, member_of(other, avery))).status_code == 404
    assert other.members.count() == 2


@pytest.mark.parametrize("member_id", ["not-a-uuid", "1234", "x" * 200])
def test_iso_3_a_malformed_member_id_is_404(group, maya, member_id):
    assert maya.client.delete(f"{BASE}{group.id}/members/{member_id}/").status_code == 404


@pytest.mark.parametrize("group_id", ["not-a-uuid", "1234", "%20", "x" * 200])
def test_iso_3_a_malformed_group_id_is_404_for_every_write(maya, jordan, group_id):
    group = make_group(maya, jordan)
    assert jordan.client.put(f"{BASE}{group_id}/", {}, format="json").status_code == 404
    assert maya.client.delete(f"{BASE}{group_id}/").status_code == 404
    assert maya.client.delete(f"{BASE}{group_id}/members/{member_of(group, jordan).id}/").status_code == 404
    assert maya.client.post(f"{BASE}{group_id}/invite").status_code == 404


def test_ver_8_the_etag_changes_when_someone_leaves_or_is_removed(group, maya, jordan):
    casey = person("Casey Kim")
    assert join(casey, group).status_code == 200
    for who, by in ((casey, casey), (jordan, maya)):
        old = maya.client.get(detail(group.id))["ETag"]
        assert by.client.delete(member_path(group, member_of(group, who))).status_code == 204
        response = maya.client.get(detail(group.id), HTTP_IF_NONE_MATCH=old)
        assert response.status_code == 200
        assert who.profile.name.split()[0] not in [m["name"] for m in response.json()["members"]]


def test_n_12_a_member_who_left_is_not_named_in_a_409(group, maya, jordan):
    assert put(jordan, group).status_code == 200
    assert jordan.client.delete(member_path(group, member_of(group, jordan))).status_code == 204
    response = put(maya, group, base=3)
    assert response.status_code == 409
    assert response.json()["edits"] == [
        {
            "version": 4,
            "authorId": None,
            "authorName": None,
            "kind": "remove",
            "stopIds": GroupPlanEdit.objects.get().stop_ids,
        }
    ]
    assert "Jordan" not in response.content.decode()


def test_cas_4_the_organizer_ends_the_group_and_everything_in_it_goes(group, maya, jordan):
    token = token_of(group)
    assert put(jordan, group).status_code == 200
    GroupRemoval.objects.create(group=group, profile_id=uuid.uuid4())

    assert maya.client.delete(detail(group.id)).status_code == 204
    for model in (GroupPlan, GroupMember, GroupPlanEdit, GroupRemoval):
        assert not model.objects.exists(), model
    assert jordan.client.get(detail(group.id)).status_code == 404
    assert jordan.client.get(BASE).json() == {"groups": []}
    assert person("Sam Rivera").client.get(preview_path(token)).status_code == 404
    assert maya.client.delete(detail(group.id)).status_code == 404


def test_only_the_organizer_ends_the_group(group, jordan):
    before = row(group)
    assert jordan.client.delete(detail(group.id)).status_code == 404
    assert person("Sam Rivera").client.delete(detail(group.id)).status_code == 404
    assert row(group) == before
    assert group.members.count() == 2
