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
    email = "" if is_anonymous else (email or f"{name.split()[0].lower()}-{profile_id.hex[:6]}@columbia.edu")
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
