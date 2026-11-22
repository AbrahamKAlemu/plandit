"""A friend's answer on a friends' input link, and the organizer deleting or building it, at the same
moment (group plans, mode 2, slice G2a).

The answer view saves with the request's row locked, as the shared plan's answer view does. If a
delete looked for the request's answers before taking that lock, an answer saved meanwhile would
be missed: the delete then fails at commit (a new answer) or deadlocks with the save (a changed
answer). These tests hold the friend's save inside the lock until the organizer's request is
blocked, which is the order that goes wrong, so they don't depend on timing (the pattern of
test_answer_races.py)."""

import threading

import pytest
from django.db import connection
from django.test import Client

from plandit.core.models import Profile
from plandit.plans.models import GroupAnswer, GroupRequest
from plandit.shares.models import SharedPlan
from tests.test_answer_races import WAIT_SECONDS, another_session_is_waiting_for_a_lock, delete_account
from tests.test_answers import empty_throttle_cache  # noqa: F401
from tests.test_requests import friend_answer, make_request
from tests.test_shares import plan_payload, share

pytestmark = pytest.mark.django_db(transaction=True)


def friend_saves_while_organizer_acts(monkeypatch, friend_request, organizer_request) -> dict:
    """Run the friend's answer POST; once it holds the request's lock, start the organizer's
    request, wait until that request is blocked, then let the friend save and commit."""
    holding = threading.Event()
    results = {}
    save = GroupAnswer.objects.update_or_create

    def save_once_the_organizer_waits(*args, **kwargs):
        holding.set()
        results["organizer_was_blocked"] = another_session_is_waiting_for_a_lock()
        return save(*args, **kwargs)

    monkeypatch.setattr(GroupAnswer.objects, "update_or_create", save_once_the_organizer_waits)

    def friend():
        try:
            results["friend"] = friend_request().status_code
        finally:
            connection.close()

    def organizer():
        try:
            assert holding.wait(WAIT_SECONDS), "the friend never reached the save"
            results["organizer"] = organizer_request().status_code
        finally:
            connection.close()

    threads = [threading.Thread(target=friend), threading.Thread(target=organizer)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(WAIT_SECONDS * 3)
    assert not any(thread.is_alive() for thread in threads), "a request never finished"
    return results


@pytest.fixture
def link(auth_client, profile):
    """An open request with Sam's answer on it."""
    auth_client.raise_request_exception = False
    slug = make_request(profile).slug
    sam = Client(raise_request_exception=False)
    assert friend_answer(sam, slug, name="Sam").status_code == 303
    return slug, sam


def answering(link, friend_is):
    slug, sam = link
    browser = Client(raise_request_exception=False) if friend_is == "new" else sam
    name = "Maya" if friend_is == "new" else "Sam"
    return lambda: friend_answer(browser, slug, name=name, budget="10")


@pytest.mark.parametrize("friend_is", ["new", "changing their answer"])
def test_deleting_the_request_while_a_friend_answers_deletes_it_and_every_answer(
    auth_client, link, monkeypatch, friend_is
):
    slug, _ = link
    results = friend_saves_while_organizer_acts(
        monkeypatch, answering(link, friend_is), lambda: auth_client.delete(f"/api/plan-requests/{slug}/")
    )

    assert results == {"organizer_was_blocked": True, "friend": 303, "organizer": 204}
    assert not GroupRequest.objects.filter(slug=slug).exists()
    assert GroupAnswer.objects.count() == 0


@pytest.mark.parametrize("with_supabase", [False, True], ids=["local-only", "with-supabase"])
@pytest.mark.parametrize("friend_is", ["new", "changing their answer"])
def test_deleting_the_account_while_a_friend_answers_deletes_the_request_and_every_answer(
    auth_client, user_id, link, monkeypatch, settings, friend_is, with_supabase
):
    results = friend_saves_while_organizer_acts(
        monkeypatch, answering(link, friend_is), delete_account(auth_client, settings, monkeypatch, with_supabase)
    )

    assert results == {"organizer_was_blocked": True, "friend": 303, "organizer": 204}
    assert not Profile.objects.filter(pk=user_id).exists()
    assert not GroupRequest.objects.exists()
    assert GroupAnswer.objects.count() == 0


def test_building_while_a_friend_answers_keeps_the_answer_and_then_builds(auth_client, link, monkeypatch):
    """The share waits for the friend's save, so an answer that made it in before the plan was
    built is kept for the organizer, and the link opens the plan from then on."""
    slug, _ = link
    results = friend_saves_while_organizer_acts(
        monkeypatch, answering(link, "new"), lambda: share(auth_client, plan_payload(request=slug))
    )

    assert results == {"organizer_was_blocked": True, "friend": 303, "organizer": 201}
    group = GroupRequest.objects.get(slug=slug)
    assert (group.status, group.shared_plan) == ("built", SharedPlan.objects.get())
    assert sorted(group.answers.values_list("name", flat=True)) == ["Maya", "Sam"]
