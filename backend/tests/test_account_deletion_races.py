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

import pytest

from plandit.core import views as core_views
from plandit.core.models import AppSnapshot, Profile
from tests.test_group_plan_races import delete_account_later, first_holds_until_second_waits, second_device
from tests.test_group_plans import person, plan_json, with_and_without_supabase

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
