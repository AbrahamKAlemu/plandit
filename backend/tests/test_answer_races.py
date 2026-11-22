"""A friend's answer and the owner deleting the link, at the same moment (brief GV-10).

The answer view saves with the link's row locked. If a delete looked for the link's answers before
taking that lock, an answer saved meanwhile would be missed: the link's delete then fails at commit
(a new answer) or deadlocks with the save (a changed answer), and the link stays up. These tests
hold the friend's save inside the lock until the owner's request is blocked, which is the order
that goes wrong, so they don't depend on timing."""

import threading
import time

import httpx
import pytest
from django.db import connection
from django.test import Client

from plandit.core.models import Profile
from plandit.shares.models import ShareAnswer, SharedPlan
from tests.test_account_delete import FakeDelete
from tests.test_answers import answer, answers_payload, empty_throttle_cache  # noqa: F401
from tests.test_shares import share

pytestmark = pytest.mark.django_db(transaction=True)

WAIT_SECONDS = 10


def another_session_is_waiting_for_a_lock() -> bool:
    """pg_locks is read live (pg_stat_activity would be a snapshot inside a transaction)."""
    deadline = time.monotonic() + WAIT_SECONDS
    with connection.cursor() as cursor:
        while time.monotonic() < deadline:
            cursor.execute("SELECT count(*) FROM pg_locks WHERE NOT granted")
            if cursor.fetchone()[0]:
                return True
            time.sleep(0.02)
    return False


def friend_saves_while_owner_deletes(monkeypatch, friend_request, owner_request) -> dict:
    """Run the friend's answer POST; once it holds the link's lock, start the owner's request, wait
    until that request is blocked, then let the friend save and commit."""
    holding = threading.Event()
    results = {}
    save = ShareAnswer.objects.update_or_create

    def save_once_the_owner_waits(*args, **kwargs):
        holding.set()
        results["owner_was_blocked"] = another_session_is_waiting_for_a_lock()
        return save(*args, **kwargs)

    monkeypatch.setattr(ShareAnswer.objects, "update_or_create", save_once_the_owner_waits)

    def friend():
        try:
            results["friend"] = friend_request().status_code
        finally:
            connection.close()

    def owner():
        try:
            assert holding.wait(WAIT_SECONDS), "the friend never reached the save"
            results["owner"] = owner_request().status_code
        finally:
            connection.close()

    threads = [threading.Thread(target=friend), threading.Thread(target=owner)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(WAIT_SECONDS * 3)
    assert not any(thread.is_alive() for thread in threads), "a request never finished"
    return results


@pytest.fixture
def link(auth_client):
    auth_client.raise_request_exception = False
    slug = share(auth_client, answers_payload()).json()["slug"]
    sam = Client(raise_request_exception=False)
    assert answer(sam, slug, name="Sam").status_code == 303
    return slug, sam


def stop_sharing(auth_client, slug):
    return lambda: auth_client.delete(f"/api/shares/{slug}/")


def delete_account(auth_client, settings, monkeypatch, with_supabase):
    """DELETE /api/me/, with Supabase answering 200, or without a service key (local data only)."""
    settings.SUPABASE_SERVICE_ROLE_KEY = "service-role-key-for-tests" if with_supabase else ""
    monkeypatch.setattr(httpx, "delete", FakeDelete(200))
    return lambda: auth_client.delete("/api/me/")


@pytest.mark.parametrize("friend_is", ["new", "changing their answer"])
def test_stop_sharing_while_a_friend_answers_deletes_the_link_and_every_answer(
    auth_client, link, monkeypatch, friend_is
):
    slug, sam = link
    browser = Client(raise_request_exception=False) if friend_is == "new" else sam
    results = friend_saves_while_owner_deletes(
        monkeypatch,
        lambda: answer(browser, slug, name="Maya" if friend_is == "new" else "Sam", status="out"),
        stop_sharing(auth_client, slug),
    )

    assert results == {"owner_was_blocked": True, "friend": 303, "owner": 204}
    assert not SharedPlan.objects.filter(slug=slug).exists()
    assert ShareAnswer.objects.count() == 0


@pytest.mark.parametrize("with_supabase", [False, True], ids=["local-only", "with-supabase"])
@pytest.mark.parametrize("friend_is", ["new", "changing their answer"])
def test_deleting_the_account_while_a_friend_answers_deletes_the_link_and_every_answer(
    auth_client, user_id, link, monkeypatch, settings, friend_is, with_supabase
):
    slug, sam = link
    browser = Client(raise_request_exception=False) if friend_is == "new" else sam
    results = friend_saves_while_owner_deletes(
        monkeypatch,
        lambda: answer(browser, slug, name="Maya" if friend_is == "new" else "Sam", status="out"),
        delete_account(auth_client, settings, monkeypatch, with_supabase),
    )

    assert results == {"owner_was_blocked": True, "friend": 303, "owner": 204}
    assert not Profile.objects.filter(pk=user_id).exists()
    assert not SharedPlan.objects.exists()
    assert ShareAnswer.objects.count() == 0
