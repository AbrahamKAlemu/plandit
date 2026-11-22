"""Account deletion at the same moment as another write of the same account's data: a snapshot sync
from another device, and a share from another device. (Group plan writes against deletion are in
test_group_plan_races.py, friends' answers in test_answer_races.py and test_request_races.py.)

Deletion locks the profile first, then the account's shared plans, friends' input links and group
plans by primary key, then deletes the profile, which cascades to everything else (core.views).
A write that took a lock on the account's data before the profile's, and then waited for the
profile, deadlocked with it; one that never took the profile's lock failed at commit, when its new
row's foreign key found the profile gone. Either way the request answered 500, and a deletion that
lost the deadlock failed after Supabase had already removed the sign-in.

Each test holds one request at the step where the order matters until the other is seen waiting
for a lock (first_holds_until_second_waits), so they don't depend on timing."""

from datetime import timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.db import DatabaseError

from plandit.core import retention
from plandit.core import views as core_views
from plandit.core.models import AppSnapshot, Profile
from plandit.plans.models import REQUEST_RETENTION_DAYS, GroupAnswer, GroupRequest
from plandit.shares.models import SharedPlan
from tests.test_group_plan_races import delete_account_later, first_holds_until_second_waits, second_device, warm
from tests.test_group_plans import person, plan_json, with_and_without_supabase
from tests.test_requests import add_answer, local_today, make_request
from tests.test_shares import plan_payload, share

pytestmark = pytest.mark.django_db(transaction=True)

ACCOUNT_DELETED = {"detail": "Account deleted."}


@pytest.fixture
def maya():
    return person("Maya Lopez")


# --- A snapshot sync from another device ---------------------------------------------------------


def sync(who):
    """The app's PUT of its whole store, with the profile block it always sends (mirrored into the
    Profile row) and a plan with stops (which activates the account)."""
    data = {
        "today": plan_json(),
        "saved": [],
        "pastPlans": [],
        "profile": {"name": "Maya Lopez", "school": "Columbia University", "defaultBudget": 45.0},
    }
    return who.client.put("/api/me/snapshot/", {"data": data}, format="json")


@with_and_without_supabase
@pytest.mark.parametrize("first", ["sync", "deletion"])
def test_a_sync_and_the_accounts_deletion_both_finish(maya, settings, monkeypatch, with_supabase, first):
    """The sync locked the snapshot, then the profile, to copy the profile's fields into it; the
    deletion locks the profile, then deletes the snapshot. Each waited for the other. The sync now
    locks the profile first, as deletion does: it either commits before the deletion starts, or
    waits for it and gets the same 401 as any request from a deleted account."""
    assert sync(maya).status_code == 200  # a snapshot to lock, and today's activity recorded
    phone = second_device(maya)
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    if first == "sync":
        # Held before it copies the profile: with the snapshot (and now the profile) locked.
        results = first_holds_until_second_waits(
            monkeypatch, core_views, "_mirror_profile", lambda: sync(phone), delete, before=True
        )
        synced, deleted = results["first"], results["second"]
    else:
        results = first_holds_until_second_waits(
            monkeypatch, core_views, "_lock_group_plans", delete, lambda: sync(phone)
        )
        deleted, synced = results["first"], results["second"]

    assert (deleted.status_code, synced.status_code) == (204, 200 if first == "sync" else 401)
    if first == "deletion":
        assert synced.json() == ACCOUNT_DELETED
    assert not Profile.objects.filter(pk=maya.id).exists()
    assert not AppSnapshot.objects.exists()


# --- Sharing a plan from another device ----------------------------------------------------------


@with_and_without_supabase
@pytest.mark.parametrize("plan_is", ["new", "shared before"])
@pytest.mark.parametrize("first", ["share", "deletion"])
def test_a_share_and_the_accounts_deletion_both_finish(maya, settings, monkeypatch, with_supabase, plan_is, first):
    """A share without `request` never locked the profile. A new link's row checks its owner when
    the share commits (Django's foreign keys are deferred), so a share that committed after the
    deletion failed with an IntegrityError, a 500. It now takes the profile's lock first, as a share
    with `request` does: the deletion waits for it and deletes the new link, or it waits for the
    deletion and gets the same 401 as any request from a deleted account."""
    warm(maya)
    phone = second_device(maya)
    payload = plan_payload()
    if plan_is == "shared before":
        assert share(maya.client, payload).status_code == 201
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    if first == "share":
        # Held once the link is written, inside the share's transaction.
        results = first_holds_until_second_waits(
            monkeypatch, SharedPlan.objects, "update_or_create", lambda: share(phone.client, payload), delete
        )
        shared, deleted = results["first"], results["second"]
    else:
        results = first_holds_until_second_waits(
            monkeypatch, core_views, "_lock_group_plans", delete, lambda: share(phone.client, payload)
        )
        deleted, shared = results["first"], results["second"]

    shared_status = {"share": 201 if plan_is == "new" else 200, "deletion": 401}[first]
    assert (deleted.status_code, shared.status_code) == (204, shared_status)
    if first == "deletion":
        assert shared.json() == ACCOUNT_DELETED
    assert not Profile.objects.filter(pk=maya.id).exists()
    assert not SharedPlan.objects.exists()


@with_and_without_supabase
def test_a_share_with_request_that_waited_for_the_accounts_deletion_is_401(maya, settings, monkeypatch, with_supabase):
    """It answered 400 "No such request." when the request had gone with the account; now it gets
    the answer a deleted account gets everywhere else. (The other order is in test_request_races.py.)"""
    warm(maya)
    phone = second_device(maya)
    slug = make_request(maya.profile).slug
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase)
    results = first_holds_until_second_waits(
        monkeypatch, core_views, "_lock_group_plans", delete, lambda: share(phone.client, plan_payload(request=slug))
    )
    assert (results["first"].status_code, results["second"].status_code) == (204, 401)
    assert results["second"].json() == ACCOUNT_DELETED
    assert not SharedPlan.objects.exists()
    assert not GroupRequest.objects.exists()


# --- The retention purge on an expired friends' input link ---------------------------------------


def purge_by(trigger: str):
    """The purge as a callable for a race: the command (its result, or the error it raised), or an
    organizer's GET of their own request, which runs it first."""
    if trigger == "the purge command":

        def run():
            try:
                call_command("purge_expired", stdout=StringIO())
            except DatabaseError as exc:
                return type(exc).__name__
            return "purged"

        return run
    sam = person("Sam Rivera")
    warm(sam)
    slug = make_request(sam.profile).slug
    return lambda: sam.client.get(f"/api/plan-requests/{slug}/")


@pytest.mark.parametrize("trigger", ["the purge command", "an organizer's GET"])
@pytest.mark.parametrize("first", ["purge", "deletion"])
def test_the_purge_and_the_accounts_deletion_on_an_expired_request_both_finish(
    maya, settings, monkeypatch, caplog, first, trigger
):
    """The purge deleted an expired request's answers, then the request, without locking it first;
    the organizer's account deletion locks the request, then deletes its answers. Each waited for
    the other. The purge now locks expired requests first, in primary-key order, as account
    deletion, the organizer's delete and a friend's answer do (the group plan rule's `lock_first`)."""
    expired = make_request(maya.profile, day=local_today() - timedelta(days=REQUEST_RETENTION_DAYS))
    add_answer(expired, name="Jordan")
    warm(maya)
    purge = purge_by(trigger)
    delete = delete_account_later(maya, settings, monkeypatch, with_supabase=False)
    if first == "purge":
        results = first_holds_until_second_waits(
            monkeypatch, retention, "lock_rows", purge, delete, when=lambda rows: rows.model is GroupRequest
        )
        purged, deleted = results["first"], results["second"]
    else:
        results = first_holds_until_second_waits(monkeypatch, core_views, "_lock_group_plans", delete, purge)
        deleted, purged = results["first"], results["second"]

    purge_outcome = purged if trigger == "the purge command" else purged.status_code
    assert (deleted.status_code, purge_outcome) == (204, "purged" if trigger == "the purge command" else 200)
    assert "deadlock" not in caplog.text
    assert not GroupRequest.objects.filter(pk=expired.pk).exists()
    assert not GroupAnswer.objects.filter(request_id=expired.pk).exists()
    assert not Profile.objects.filter(pk=maya.id).exists()
