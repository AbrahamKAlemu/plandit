"""Group plan writes at the same moment as each other and as account deletion (slice G3a; MF-E,
brief GE-1, GE-5, GE-7, GE-8, GE-10; CON-1 to CON-11 in docs/features/group-plans/03-plan_g3-tests.md).

Each test runs a first request and holds it inside one of the steps that write after the group's
lock is taken (`_write_plan`, `_add_member`, `_remove_member`, `_replace_token`, `_end_group`,
`_create_group`, or the deletion's `_lock_group_plans`) until the second request is seen waiting for
a lock. That forces the order that goes wrong, so the tests don't depend on timing, and each one
asserts the second request really was blocked."""

import threading

import pytest
from django.db import connection, transaction

from plandit.core import views as core_views
from plandit.core.models import Profile
from plandit.groups import views as group_views
from plandit.groups.models import GroupMember, GroupPlan, GroupPlanEdit, GroupRemoval
from tests.test_answer_races import WAIT_SECONDS, another_session_is_waiting_for_a_lock
from tests.test_group_plans import (
    BASE,
    Person,
    create,
    detail,
    edited,
    join,
    join_path,
    make_group,
    member_of,
    member_path,
    person,
    plan_json,
    put,
    row,
    token_of,
    with_and_without_supabase,
)

pytestmark = pytest.mark.django_db(transaction=True)


def first_holds_until_second_waits(monkeypatch, module, helper: str, first, second) -> dict:
    """Run `first`. Right after its first call to `module.<helper>`, with that request's locks held,
    start `second`, wait until a session is waiting for a lock, then let `first` commit. Returns
    both responses and whether `second` was seen blocked. Later calls to the helper run as normal."""
    original = getattr(module, helper)
    holding = threading.Event()
    results = {}

    def hold_the_first_call(*args, **kwargs):
        value = original(*args, **kwargs)
        if not holding.is_set():
            holding.set()
            results["second_was_blocked"] = another_session_is_waiting_for_a_lock()
        return value

    monkeypatch.setattr(module, helper, hold_the_first_call)

    def run_first():
        try:
            results["first"] = first()
        finally:
            connection.close()

    def run_second():
        try:
            assert holding.wait(WAIT_SECONDS), f"the first request never reached {helper}"
            results["second"] = second()
        finally:
            connection.close()

    threads = [threading.Thread(target=run_first), threading.Thread(target=run_second)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(WAIT_SECONDS * 3)
    assert not any(thread.is_alive() for thread in threads), "a request never finished"
    assert results.get("second_was_blocked") is True, "the second request was never blocked"
    return results


def warm(*people: Person) -> None:
    """One request each first, so no request in the race records today's activity: that write
    locks the profile row on its own and would blur what the race tests."""
    for who in people:
        assert who.client.get(BASE).status_code == 200


def statuses(results) -> tuple[int, int]:
    return results["first"].status_code, results["second"].status_code


@pytest.fixture
def maya():
    return person("Maya Lopez")


@pytest.fixture
def jordan():
    return person("Jordan Lee")


@pytest.fixture
def casey():
    return person("Casey Kim")


@pytest.fixture
def group(maya, jordan, casey):
    group = make_group(maya, jordan, casey, version=3, members_version=2)
    warm(maya, jordan, casey)
    return group


# --- PUT against PUT ---------------------------------------------------------------------------


def test_con_1_two_puts_from_the_same_version_give_one_200_and_one_409(group, maya, jordan, monkeypatch):
    plan_a, plan_b = edited(group), edited(group)
    plan_a["title"], plan_b["title"] = "Maya's", "Jordan's"
    results = first_holds_until_second_waits(
        monkeypatch,
        group_views,
        "_write_plan",
        lambda: put(maya, group, plan_a, base=3),
        lambda: put(jordan, group, plan_b, base=3),
    )
    assert statuses(results) == (200, 409)
    conflict = results["second"].json()
    assert (conflict["version"], conflict["plan"]["title"]) == (4, "Maya's")
    assert [(e["version"], e["authorName"]) for e in conflict["edits"]] == [(4, "Maya")]
    group.refresh_from_db()
    assert (group.version, group.data["title"]) == (4, "Maya's")
    assert GroupPlanEdit.objects.count() == 1


# --- Joining against the limit and a new link ---------------------------------------------------


def test_con_2_two_joins_for_the_last_place_give_one_200_and_one_404(maya, jordan, monkeypatch):
    others = [person(f"Friend{i} Lee") for i in range(5)]
    group = make_group(maya, jordan, *others)
    assert group.members.count() == 7
    x, y = person("Sam Rivera"), person("Avery Diaz")
    warm(x, y)
    results = first_holds_until_second_waits(
        monkeypatch, group_views, "_add_member", lambda: join(x, group), lambda: join(y, group)
    )
    assert statuses(results) == (200, 404)
    assert group.members.count() == 8
    assert GroupMember.objects.filter(group=group, profile=x.profile).exists()
    assert not GroupMember.objects.filter(profile=y.profile).exists()


def test_con_4a_a_join_that_holds_the_lock_finishes_before_the_link_is_replaced(group, maya, monkeypatch):
    sam = person("Sam Rivera")
    warm(sam)
    old = token_of(group)
    results = first_holds_until_second_waits(
        monkeypatch,
        group_views,
        "_add_member",
        lambda: join(sam, group, old),
        lambda: maya.client.post(f"{BASE}{group.id}/invite"),
    )
    assert statuses(results) == (200, 200)
    assert GroupMember.objects.filter(group=group, profile=sam.profile).exists()
    assert token_of(group) != old
    assert person("Ana Cruz").client.post(join_path(old)).status_code == 404


def test_con_4b_a_join_that_waited_for_a_new_link_is_refused(group, maya, monkeypatch):
    sam = person("Sam Rivera")
    warm(sam)
    old = token_of(group)
    results = first_holds_until_second_waits(
        monkeypatch,
        group_views,
        "_replace_token",
        lambda: maya.client.post(f"{BASE}{group.id}/invite"),
        lambda: join(sam, group, old),
    )
    assert statuses(results) == (200, 404)
    assert not GroupMember.objects.filter(profile=sam.profile).exists()
    assert group.members.count() == 3


# --- Removing a member against their PUT --------------------------------------------------------


def test_con_3a_a_put_that_holds_the_lock_is_stored_then_the_member_is_removed(group, maya, jordan, monkeypatch):
    results = first_holds_until_second_waits(
        monkeypatch,
        group_views,
        "_write_plan",
        lambda: put(jordan, group, base=3),
        lambda: maya.client.delete(member_path(group, member_of(group, jordan))),
    )
    assert statuses(results) == (200, 204)
    assert jordan.client.get(detail(group.id)).status_code == 404
    group.refresh_from_db()
    assert (group.version, group.members_version) == (4, 3)


def test_con_3b_a_put_that_waited_for_its_members_removal_is_404(group, maya, jordan, monkeypatch):
    """Membership is checked again under the group's lock (mutation-checked, g3a-mutation-*.log)."""
    jordan_member = member_of(group, jordan)
    before = row(group)
    results = first_holds_until_second_waits(
        monkeypatch,
        group_views,
        "_remove_member",
        lambda: maya.client.delete(member_path(group, jordan_member)),
        lambda: put(jordan, group, base=3),
    )
    assert statuses(results) == (204, 404)
    group.refresh_from_db()
    assert (group.data, group.version) == before[:2]
    assert not GroupPlanEdit.objects.exists()


# --- The organizer's account deletion against a PUT and a join -----------------------------------


@with_and_without_supabase
def test_con_5a_a_put_that_holds_the_lock_is_stored_then_the_organizers_account_goes(
    group, maya, jordan, settings, monkeypatch, with_supabase
):
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(
        monkeypatch, group_views, "_write_plan", lambda: put(jordan, group, base=3), delete
    )
    assert statuses(results) == (200, 204)
    assert not Profile.objects.filter(pk=maya.id).exists()
    for model in (GroupPlan, GroupMember, GroupPlanEdit):
        assert not model.objects.exists(), model


@with_and_without_supabase
def test_con_5b_a_put_that_waited_for_the_organizers_account_deletion_is_404(
    group, maya, jordan, settings, monkeypatch, with_supabase
):
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(
        monkeypatch, core_views, "_lock_group_plans", delete, lambda: put(jordan, group, base=3)
    )
    assert statuses(results) == (204, 404)
    assert not GroupPlan.objects.exists()


@with_and_without_supabase
def test_con_6a_a_join_that_holds_the_lock_commits_then_the_organizers_account_goes(
    group, maya, settings, monkeypatch, with_supabase
):
    """No IntegrityError at commit: the new member row is deleted with the group."""
    sam = person("Sam Rivera")
    warm(sam)
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(monkeypatch, group_views, "_add_member", lambda: join(sam, group), delete)
    assert statuses(results) == (200, 204)
    assert not GroupPlan.objects.exists()
    assert not GroupMember.objects.exists()
    assert sam.client.get(BASE).json() == {"groups": []}


@with_and_without_supabase
def test_con_6b_a_join_that_waited_for_the_organizers_account_deletion_is_404(
    group, maya, settings, monkeypatch, with_supabase
):
    sam = person("Sam Rivera")
    warm(sam)
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(
        monkeypatch, core_views, "_lock_group_plans", delete, lambda: join(sam, group)
    )
    assert statuses(results) == (204, 404)
    assert not GroupMember.objects.exists()


@with_and_without_supabase
def test_con_6c_a_joiner_deleting_their_account_waits_for_their_join(group, settings, monkeypatch, with_supabase):
    """The join holds the joiner's profile from its start, so the deletion waits and then takes
    the new membership with it."""
    sam = person("Sam Rivera")
    warm(sam)
    delete = delete_account_later(sam, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(monkeypatch, group_views, "_add_member", lambda: join(sam, group), delete)
    assert statuses(results) == (200, 204)
    assert not Profile.objects.filter(pk=sam.id).exists()
    assert group.members.count() == 3
    group.refresh_from_db()
    assert group.members_version == 4  # up once for the join, once for the deletion


# --- A member's own account deletion against their PUT from another device ----------------------


def second_device(who: Person) -> Person:
    """The same account signed in on another phone: same token, another client."""
    from rest_framework.test import APIClient

    client = APIClient(raise_request_exception=False)
    client.credentials(HTTP_AUTHORIZATION=who.client._credentials["HTTP_AUTHORIZATION"])
    return Person(who.profile, client)


@with_and_without_supabase
@pytest.mark.parametrize("first", ["put", "deletion"])
def test_con_7_a_members_put_and_their_account_deletion_both_finish(
    group, maya, jordan, settings, monkeypatch, with_supabase, first
):
    phone = second_device(jordan)
    delete = delete_account_later(jordan, settings, monkeypatch, with_supabase)
    if first == "put":
        results = first_holds_until_second_waits(
            monkeypatch, group_views, "_write_plan", lambda: put(phone, group, base=3), delete
        )
        put_response, delete_response = results["first"], results["second"]
    else:
        results = first_holds_until_second_waits(
            monkeypatch, core_views, "_lock_group_plans", delete, lambda: put(phone, group, base=3)
        )
        delete_response, put_response = results["first"], results["second"]

    assert delete_response.status_code == 204
    assert put_response.status_code in (200, 401, 404)
    assert put_response.status_code == (200 if first == "put" else 404)
    assert not Profile.objects.filter(pk=jordan.id).exists()
    assert not GroupMember.objects.filter(profile_id=jordan.id).exists()
    group.refresh_from_db()
    assert [m.display_name for m in group.members.order_by("joined_at")] == ["Maya", "Casey"]
    assert maya.client.get(detail(group.id)).status_code == 200


# --- Ending the group against a PUT and a join ---------------------------------------------------


@pytest.mark.parametrize("other", ["put", "join"])
def test_con_8_a_write_that_waited_for_the_group_to_end_is_404(group, maya, jordan, monkeypatch, other):
    sam = person("Sam Rivera")
    warm(sam)
    second = (lambda: put(jordan, group, base=3)) if other == "put" else (lambda: join(sam, group))
    results = first_holds_until_second_waits(
        monkeypatch, group_views, "_end_group", lambda: maya.client.delete(detail(group.id)), second
    )
    assert statuses(results) == (204, 404)
    assert not GroupPlan.objects.exists()
    assert not GroupMember.objects.exists()


@pytest.mark.parametrize("other", ["put", "join"])
def test_con_8_a_write_that_holds_the_lock_commits_then_the_group_ends(group, maya, jordan, monkeypatch, other):
    sam = person("Sam Rivera")
    warm(sam)
    first, helper = (
        ((lambda: put(jordan, group, base=3)), "_write_plan")
        if other == "put"
        else ((lambda: join(sam, group)), "_add_member")
    )
    results = first_holds_until_second_waits(
        monkeypatch, group_views, helper, first, lambda: maya.client.delete(detail(group.id))
    )
    assert statuses(results) == (200, 204)
    assert jordan.client.get(detail(group.id)).status_code == 404
    for model in (GroupPlan, GroupMember, GroupPlanEdit):
        assert not model.objects.exists(), model


# --- Leaving against being removed ---------------------------------------------------------------


@pytest.mark.parametrize("first", ["leave", "removal"])
def test_con_9_leaving_and_being_removed_at_once_give_204_and_404(group, maya, jordan, monkeypatch, first):
    path = member_path(group, member_of(group, jordan))
    leave, remove = (lambda: jordan.client.delete(path)), (lambda: maya.client.delete(path))
    requests = (leave, remove) if first == "leave" else (remove, leave)
    results = first_holds_until_second_waits(monkeypatch, group_views, "_remove_member", *requests)
    assert statuses(results) == (204, 404)
    assert not GroupMember.objects.filter(profile=jordan.profile).exists()
    assert GroupRemoval.objects.filter(profile_id=jordan.id).exists() is (first == "removal")
    group.refresh_from_db()
    assert group.members_version == 3


# --- Two creates of the same plan ----------------------------------------------------------------


def test_con_11_two_creates_of_the_same_plan_make_one_group(maya, monkeypatch):
    warm(maya)
    plan = plan_json()
    results = first_holds_until_second_waits(
        monkeypatch, group_views, "_create_group", lambda: create(maya, plan), lambda: create(maya, plan)
    )
    assert statuses(results) == (201, 200)
    assert results["first"].json()["id"] == results["second"].json()["id"]
    assert GroupPlan.objects.count() == 1
    assert GroupMember.objects.count() == 1


# --- lock_timeout: a write that waits too long is 503 (N-13) -------------------------------------


def hold_row_lock(sql: str, params, release: threading.Event, held: threading.Event):
    try:
        with transaction.atomic(), connection.cursor() as cursor:
            cursor.execute(sql, params)
            held.set()
            release.wait(WAIT_SECONDS)
    finally:
        connection.close()


@pytest.mark.parametrize("request_kind", ["put", "join"])
def test_a_write_that_waits_past_the_lock_timeout_is_503(group, jordan, monkeypatch, request_kind):
    monkeypatch.setattr(group_views, "LOCK_TIMEOUT", "200ms")
    sam = person("Sam Rivera")
    warm(sam)
    release, held = threading.Event(), threading.Event()
    holder = threading.Thread(
        target=hold_row_lock,
        args=("SELECT 1 FROM groups_groupplan WHERE id = %s FOR UPDATE", [group.id], release, held),
    )
    holder.start()
    try:
        assert held.wait(WAIT_SECONDS)
        before = row(group)
        response = put(jordan, group, base=3) if request_kind == "put" else join(sam, group)
    finally:
        release.set()
        holder.join(WAIT_SECONDS)
    assert response.status_code == 503
    assert response.json() == {"detail": "Try again in a moment."}
    assert response["Retry-After"] == "1"
    assert row(group) == before
    assert not GroupMember.objects.filter(profile=sam.profile).exists()
    # Once the lock is free, the same request goes through.
    again = put(jordan, group, base=3) if request_kind == "put" else join(sam, group)
    assert again.status_code == 200


def delete_account_later(who: Person, settings, monkeypatch, with_supabase: bool):
    """`delete_account` as a callable for a race: settings are applied now, the DELETE runs later."""
    import httpx

    from tests.test_account_delete import FakeDelete

    settings.SUPABASE_SERVICE_ROLE_KEY = "service-role-key-for-tests" if with_supabase else ""
    monkeypatch.setattr(httpx, "delete", FakeDelete(200))
    return lambda: who.client.delete("/api/me/")


# --- ISO-2 with the group's row locked: an outsider's write is 404 without waiting ---------------


def outsider_write(route: str, who: Person, group_id, member_id):
    if route == "end":
        return who.client.delete(detail(group_id))
    if route == "remove":
        return who.client.delete(f"{BASE}{group_id}/members/{member_id}/")
    return who.client.post(f"{BASE}{group_id}/invite")


@pytest.mark.parametrize(
    ("route", "actor"),
    [("end", "outsider"), ("end", "member"), ("remove", "outsider"), ("new link", "outsider"), ("new link", "member")],
)
def test_iso_2_an_outsider_gets_the_same_404_while_the_group_is_locked(group, maya, jordan, monkeypatch, route, actor):
    """These routes checked the caller only after taking the group's lock. With the row held past
    LOCK_TIMEOUT, the real group answered 503 and a random id 404, which told them apart."""
    import uuid

    monkeypatch.setattr(group_views, "LOCK_TIMEOUT", "200ms")
    sam = person("Sam Rivera")
    warm(sam)
    caller = sam if actor == "outsider" else jordan
    member_id = member_of(group, jordan).id
    before = row(group)
    release, held = threading.Event(), threading.Event()
    holder = threading.Thread(
        target=hold_row_lock,
        args=("SELECT 1 FROM groups_groupplan WHERE id = %s FOR UPDATE", [group.id], release, held),
    )
    holder.start()
    try:
        assert held.wait(WAIT_SECONDS)
        pair = [outsider_write(route, caller, gid, member_id) for gid in (group.id, uuid.uuid4())]
    finally:
        release.set()
        holder.join(WAIT_SECONDS)
    assert [r.status_code for r in pair] == [404, 404]
    assert pair[0].content == pair[1].content == b""
    assert not pair[0].has_header("ETag") and not pair[1].has_header("ETag")
    assert not pair[0].has_header("Retry-After")
    assert row(group) == before
    assert group.members.count() == 3
