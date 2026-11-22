"""Friends answer a shared plan's page (group plans, slice G1a; brief GV-1 to GV-12, GS-1 to GS-5).

The form only appears on plans shared with `answers: true` (the G1b app sends it), so pages shared
by today's app look exactly as before (test_shares.py covers those)."""

import hashlib
import re
import time
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from django.core.cache import caches
from django.db import connection
from django.test import Client
from django.utils import timezone

from plandit.core import public_forms, retention
from plandit.shares.models import ShareAnswer, SharedPlan
from tests.test_shares import PUBLIC_PAGE_CSP, plan_payload, share

pytestmark = pytest.mark.django_db

# The app sends Swift UUIDs, which are upper case; they come back exactly as sent.
MET = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
TACOS = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
MOMA = "11111111-2222-4333-8444-555555555555"
GUGGENHEIM = "22222222-3333-4444-8555-666666666666"
PIZZA = "33333333-4444-4555-8666-777777777777"


def answers_payload(plan_id=None, **overrides):
    payload = plan_payload(plan_id, answers=True, date=(timezone.localdate() + timedelta(days=1)).isoformat())
    payload["stops"][0].update(
        id=MET,
        alternates=[
            {"id": MOMA, "name": "MoMA", "neighborhood": "Midtown", "kind": "Culture", "costText": "$30"},
            {"id": GUGGENHEIM, "name": "The Guggenheim", "neighborhood": "Upper East Side", "kind": "Culture"},
        ],
    )
    payload["stops"][1].update(
        id=TACOS,
        alternates=[
            {"id": PIZZA, "name": "Prince Street Pizza", "neighborhood": "Nolita", "kind": "Food", "costText": "$6"}
        ],
    )
    payload.update(overrides)
    return payload


@pytest.fixture(autouse=True)
def empty_throttle_cache():
    caches["throttle"].clear()
    yield
    caches["throttle"].clear()


@pytest.fixture
def plan_id():
    return uuid.uuid4()


@pytest.fixture
def slug(auth_client, plan_id):
    response = share(auth_client, answers_payload(plan_id))
    assert response.status_code == 201
    return response.json()["slug"]


@pytest.fixture
def browser():
    return Client()


def new_browser():
    return Client()


def answer(client, slug, name="Maya", status="in", swaps=None, **extra):
    """Submit the page's form the way a browser does: checked "I'd swap this" boxes as `swap`, the
    picked alternate for each as `swap_to_<stop id>`, and the pressed button as `status`."""
    data = {"name": name}
    if status is not None:
        data["status"] = status
    swaps = swaps or {}
    if swaps:
        data["swap"] = list(swaps)
    for stop_id, alternate_id in swaps.items():
        if alternate_id:
            data[f"swap_to_{stop_id}"] = alternate_id
    return client.post(f"/p/{slug}/answer", data, **extra)


def take_back(client, slug, **extra):
    return client.post(f"/p/{slug}/answer/delete", {}, **extra)


def page(client, slug):
    return client.get(f"/p/{slug}")


def html(response):
    return response.content.decode()


# --- GV-1: a first name and "I'm in" or "Can't make it" -----------------------


def test_im_in_with_a_first_name_is_stored_and_goes_back_to_the_page(browser, slug):
    response = answer(browser, slug, name="  Maya  ", status="in")

    assert response.status_code == 303
    assert response["Location"] == f"/p/{slug}"
    stored = ShareAnswer.objects.get()
    assert (stored.name, stored.status, stored.swaps) == ("Maya", "in", {})
    assert stored.shared_plan.slug == slug
    assert stored.plan_date == timezone.localdate() + timedelta(days=1)


def test_cant_make_it_is_stored_as_out(browser, slug):
    assert answer(browser, slug, name="Jordan", status="out").status_code == 303
    assert ShareAnswer.objects.get().status == "out"


def test_the_browser_gets_a_cookie_for_this_link_only_and_only_its_hash_is_stored(browser, slug):
    response = answer(browser, slug)
    cookie = response.cookies["pa"]
    assert cookie["path"] == f"/p/{slug}"
    assert cookie["httponly"] is True and cookie["secure"] is True and cookie["samesite"] == "Lax"
    stored = ShareAnswer.objects.get()
    assert stored.responder == hashlib.sha256(cookie.value.encode()).hexdigest()
    assert cookie.value not in str(ShareAnswer.objects.values().get())


@pytest.mark.parametrize(
    ("name", "message"),
    [
        ("", "Enter your first name."),
        ("   ", "Enter your first name."),
        ("A" * 31, "Use 30 characters or fewer."),
        ("Maya2", "Use letters, spaces, hyphens and apostrophes only."),
        ("<b>Maya</b>", "Use letters, spaces, hyphens and apostrophes only."),
        ("Blockedword", "Please use a different name."),
    ],
)
def test_a_bad_name_shows_the_form_again_with_the_reason(browser, slug, monkeypatch, name, message):
    monkeypatch.setattr(public_forms, "name_blocklist", lambda: frozenset({"blockedword"}))
    response = answer(browser, slug, name=name)

    assert response.status_code == 400
    body = html(response)
    assert message in body
    assert 'id="answer"' in body and "I'm in" in body
    assert "The Met" in body  # the whole page, not a bare error
    assert ShareAnswer.objects.count() == 0
    assert "pa" not in response.cookies
    assert response["Cache-Control"] == "private, no-store"
    assert response["Content-Security-Policy"] == PUBLIC_PAGE_CSP


def test_the_form_keeps_what_was_typed_when_it_comes_back(browser, slug):
    body = html(answer(browser, slug, name="Maya!", swaps={TACOS: PIZZA}))
    assert 'value="Maya!"' in body
    assert re.search(rf'name="swap" value="{TACOS}"[^>]* checked', body)
    assert re.search(rf'name="swap_to_{TACOS}" value="{PIZZA}"[^>]* checked', body)


@pytest.mark.parametrize("status", [None, "", "maybe", "IN"])
def test_an_answer_needs_one_of_the_two_buttons(browser, slug, status):
    response = answer(browser, slug, status=status)
    assert response.status_code == 400
    assert "Choose “I&#x27;m in” or “Can&#x27;t make it”." in html(response)
    assert ShareAnswer.objects.count() == 0


# --- GV-2 / GV-9: "I'd swap this", with the organizer's alternates only ----------


def test_picking_an_alternate_the_organizer_listed_is_stored(browser, slug):
    answer(browser, slug, swaps={MET: GUGGENHEIM, TACOS: PIZZA})
    assert ShareAnswer.objects.get().swaps == {MET: GUGGENHEIM, TACOS: PIZZA}


def test_id_swap_this_without_a_pick_is_stored_as_null(browser, slug):
    answer(browser, slug, swaps={TACOS: None})
    assert ShareAnswer.objects.get().swaps == {TACOS: None}


def test_an_alternate_that_is_not_on_that_stop_is_ignored(browser, slug):
    # PIZZA is offered for the tacos, not for the Met; a made-up id isn't offered anywhere.
    answer(browser, slug, swaps={MET: PIZZA, TACOS: str(uuid.uuid4())})
    assert ShareAnswer.objects.get().swaps == {MET: None, TACOS: None}


def test_unknown_stop_ids_are_ignored(browser, slug):
    answer(browser, slug, swaps={str(uuid.uuid4()): MOMA, "not-a-stop": None, MET: MOMA})
    assert ShareAnswer.objects.get().swaps == {MET: MOMA}


def test_a_pick_without_id_swap_this_ticked_is_ignored(browser, slug):
    browser.post(f"/p/{slug}/answer", {"name": "Maya", "status": "in", f"swap_to_{MET}": MOMA})
    assert ShareAnswer.objects.get().swaps == {}


def test_each_stop_offers_id_swap_this_and_the_organizers_alternates(browser, slug):
    body = html(page(browser, slug))
    assert body.count("I'd swap this") == 2
    for stop_id in (MET, TACOS):
        assert re.search(rf'<input type="checkbox"[^>]* name="swap" value="{stop_id}" form="answer"', body)
    for stop_id, alternate_id in [(MET, MOMA), (MET, GUGGENHEIM), (TACOS, PIZZA)]:
        assert re.search(rf'<input type="radio" name="swap_to_{stop_id}" value="{alternate_id}" form="answer"', body)
    assert "MoMA instead" in body
    assert "Prince Street Pizza instead" in body
    assert "Food · Nolita · $6" in body


def test_without_stop_ids_there_are_no_swap_buttons_but_the_form_stays(auth_client, browser):
    payload = plan_payload(answers=True, date=timezone.localdate().isoformat())
    slug = share(auth_client, payload).json()["slug"]
    body = html(page(browser, slug))
    assert "I'd swap this" not in body
    assert 'id="answer"' in body
    answer(browser, slug, swaps={"anything": None})
    assert ShareAnswer.objects.get().swaps == {}


# --- GV-3: who's in, and never who isn't -----------------------------------------


def answer_as(slug, name, status="in"):
    response = answer(new_browser(), slug, name=name, status=status)
    assert response.status_code == 303, html(response)


@pytest.mark.parametrize(
    ("names", "line"),
    [
        (["Maya"], "Maya is in"),
        (["Maya", "Jordan"], "Maya and Jordan are in"),
        (["Maya", "Jordan", "Sam"], "Maya, Jordan and Sam are in"),
        (["Maya", "Jordan", "Sam", "Priya"], "Maya, Jordan, Sam and 1 more are in"),
        (["Maya", "Jordan", "Sam", "Priya", "Lee"], "Maya, Jordan, Sam and 2 more are in"),
    ],
)
def test_the_page_says_how_many_are_in_with_at_most_three_names(slug, names, line):
    for name in names:
        answer_as(slug, name)
    body = html(page(new_browser(), slug))
    assert f'<p class="going">{line}</p>' in body
    for hidden in names[3:]:
        assert hidden not in body


def test_nobody_in_yet_shows_no_line(slug):
    answer_as(slug, "Jordan", status="out")
    assert 'class="going"' not in html(page(new_browser(), slug))


def test_cant_make_it_names_never_appear_on_the_page(slug):
    answer_as(slug, "Maya")
    answer_as(slug, "Quentin", status="out")
    answer_as(slug, "Zelda", status="out")
    viewer = new_browser()
    answer(viewer, slug, name="Jordan", status="in")

    for client in (new_browser(), viewer):
        body = html(page(client, slug))
        assert "Quentin" not in body and "Zelda" not in body
        assert "Maya and Jordan are in" in body


def test_names_on_the_page_are_escaped(slug):
    answer_as(slug, "O'Brien")
    body = html(page(new_browser(), slug))
    assert "O&#x27;Brien is in" in body


# --- GV-4: the same browser changes or takes back its answer; nobody else can --------


def test_the_same_browser_changes_its_answer(browser, slug):
    answer(browser, slug, name="Maya", status="in", swaps={MET: MOMA})
    first = ShareAnswer.objects.get()
    response = answer(browser, slug, name="Maya J", status="out")

    assert response.status_code == 303
    assert "pa" not in response.cookies  # same cookie, not a new one
    changed = ShareAnswer.objects.get()
    assert changed.id == first.id
    assert (changed.name, changed.status, changed.swaps) == ("Maya J", "out", {})
    assert changed.created_at == first.created_at


def test_the_same_browser_sees_its_own_answer(browser, slug):
    answer(browser, slug, name="Jordan", status="out", swaps={TACOS: PIZZA})
    body = html(page(browser, slug))
    assert "You said: <strong>Can't make it</strong>" in body
    assert 'value="Jordan"' in body  # its own name, to change it
    assert re.search(rf'name="swap_to_{TACOS}" value="{PIZZA}"[^>]* checked', body)
    assert "Take back my answer" in body


def test_another_browser_gets_its_own_answer_and_cannot_touch_the_first(browser, slug):
    answer(browser, slug, name="Maya", status="in")
    other = new_browser()
    answer(other, slug, name="Maya", status="out")
    assert ShareAnswer.objects.count() == 2
    assert take_back(other, slug).status_code == 303

    remaining = ShareAnswer.objects.get()
    assert (remaining.name, remaining.status) == ("Maya", "in")
    other_page = html(page(other, slug))
    assert "You said" not in other_page and "Take back my answer" not in other_page


def test_a_forged_cookie_is_just_a_new_browser(browser, slug):
    answer(browser, slug, name="Maya")
    forger = Client()
    forger.cookies["pa"] = "x" * 43
    answer(forger, slug, name="Mallory", status="out")
    assert sorted(ShareAnswer.objects.values_list("name", "status")) == [("Mallory", "out"), ("Maya", "in")]


def test_the_same_browser_takes_back_its_answer(browser, slug):
    answer(browser, slug)
    response = take_back(browser, slug)
    assert response.status_code == 303
    assert response["Location"] == f"/p/{slug}"
    assert ShareAnswer.objects.count() == 0
    assert "You said" not in html(page(browser, slug))


def test_taking_back_without_an_answer_does_nothing(browser, slug):
    answer_as(slug, "Maya")
    assert take_back(browser, slug).status_code == 303
    assert "pa" not in browser.cookies
    assert ShareAnswer.objects.count() == 1


def test_a_cookie_only_counts_on_its_own_link(auth_client, browser, slug):
    other_slug = share(auth_client, answers_payload()).json()["slug"]
    answer(browser, slug, name="Maya")
    # The test client sends the cookie to every path, unlike a browser; it still only counts here.
    answer(browser, other_slug, name="Maya")
    assert ShareAnswer.objects.count() == 2
    take_back(browser, other_slug)
    assert ShareAnswer.objects.get().shared_plan.slug == slug


# --- Owner API: GV-5's data, GV-7, and 404 for everyone else ------------------------


def test_the_owner_lists_the_answers(auth_client, slug):
    answer_as(slug, "Maya")
    answer(new_browser(), slug, name="Jordan", status="out", swaps={TACOS: PIZZA, MET: None})
    response = auth_client.get(f"/api/shares/{slug}/answers/")

    assert response.status_code == 200
    answers = response.json()["answers"]
    assert [(a["name"], a["status"], a["swaps"]) for a in answers] == [
        ("Maya", "in", {}),
        ("Jordan", "out", {TACOS: PIZZA, MET: None}),
    ]
    stored = ShareAnswer.objects.get(name="Jordan")
    assert answers[1]["id"] == str(stored.id)
    assert set(answers[1]) == {"id", "name", "status", "swaps", "createdAt", "updatedAt"}
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", answers[1]["createdAt"])
    assert stored.responder not in response.content.decode()


def test_the_owner_lists_no_answers_yet(auth_client, slug):
    assert auth_client.get(f"/api/shares/{slug}/answers/").json() == {"answers": []}


def test_the_owner_removes_an_answer_from_the_api_and_the_page(auth_client, slug):
    answer_as(slug, "Maya")
    answer_as(slug, "Jordan")
    maya = ShareAnswer.objects.get(name="Maya")

    assert auth_client.delete(f"/api/shares/{slug}/answers/{maya.id}/").status_code == 204
    assert [a["name"] for a in auth_client.get(f"/api/shares/{slug}/answers/").json()["answers"]] == ["Jordan"]
    body = html(page(new_browser(), slug))
    assert "Jordan is in" in body and "Maya" not in body
    assert auth_client.delete(f"/api/shares/{slug}/answers/{maya.id}/").status_code == 404


def test_every_owner_endpoint_is_404_for_another_account(auth_client, other_client, slug):
    answer_as(slug, "Maya")
    maya = ShareAnswer.objects.get()
    assert other_client.get(f"/api/shares/{slug}/answers/").status_code == 404
    assert other_client.delete(f"/api/shares/{slug}/answers/{maya.id}/").status_code == 404
    assert other_client.delete(f"/api/shares/{slug}/").status_code == 404
    assert ShareAnswer.objects.count() == 1


def test_owner_endpoints_need_an_account(api_client, slug):
    answer_as(slug, "Maya")
    maya = ShareAnswer.objects.get()
    assert api_client.get(f"/api/shares/{slug}/answers/").status_code in (401, 403)
    assert api_client.delete(f"/api/shares/{slug}/answers/{maya.id}/").status_code in (401, 403)
    assert ShareAnswer.objects.count() == 1


def test_an_answer_can_only_be_removed_through_its_own_link(auth_client, slug):
    other_slug = share(auth_client, answers_payload()).json()["slug"]
    answer_as(slug, "Maya")
    maya = ShareAnswer.objects.get()
    assert auth_client.delete(f"/api/shares/{other_slug}/answers/{maya.id}/").status_code == 404
    assert ShareAnswer.objects.count() == 1


def test_unknown_links_and_answers_are_404_for_the_owner_too(auth_client, slug):
    assert auth_client.get("/api/shares/doesnotexist/answers/").status_code == 404
    assert auth_client.delete(f"/api/shares/{slug}/answers/{uuid.uuid4()}/").status_code == 404
    assert auth_client.delete(f"/api/shares/{slug}/answers/not-a-uuid/").status_code == 404


# --- GV-8: updating the plan keeps answers, minus swaps for stops that left ---------


def test_resharing_without_a_stop_drops_swaps_for_it_and_keeps_the_answers(auth_client, plan_id, slug):
    answer(new_browser(), slug, name="Maya", swaps={MET: MOMA, TACOS: PIZZA})
    answer(new_browser(), slug, name="Jordan", status="out", swaps={TACOS: None})
    payload = answers_payload(plan_id)
    payload["stops"] = payload["stops"][:1]
    payload["legs"] = []

    assert share(auth_client, payload).status_code == 200
    swaps = dict(ShareAnswer.objects.values_list("name", "swaps"))
    assert swaps == {"Maya": {MET: MOMA}, "Jordan": {}}
    assert html(page(new_browser(), slug)).count("I'd swap this") == 1


def test_resharing_without_an_alternate_keeps_the_swap_but_not_the_pick(auth_client, plan_id, slug):
    answer(new_browser(), slug, name="Maya", swaps={MET: MOMA, TACOS: PIZZA})
    payload = answers_payload(plan_id)
    payload["stops"][0]["alternates"] = payload["stops"][0]["alternates"][1:]  # MoMA is gone

    share(auth_client, payload)
    assert ShareAnswer.objects.get().swaps == {MET: None, TACOS: PIZZA}


def test_resharing_on_another_day_moves_the_answers_expiry(auth_client, plan_id, slug):
    answer_as(slug, "Maya")
    later = timezone.localdate() + timedelta(days=5)
    share(auth_client, answers_payload(plan_id, date=later.isoformat()))
    assert ShareAnswer.objects.get().plan_date == later


def test_resharing_with_answers_off_hides_the_form_and_keeps_answers_for_the_owner(auth_client, plan_id, slug):
    answer_as(slug, "Maya")
    share(auth_client, answers_payload(plan_id, answers=False))

    response = page(new_browser(), slug)
    assert 'id="answer"' not in html(response) and "Maya" not in html(response)
    assert response["Cache-Control"] == "public, max-age=60"
    assert answer(new_browser(), slug).status_code == 404
    assert [a["name"] for a in auth_client.get(f"/api/shares/{slug}/answers/").json()["answers"]] == ["Maya"]


def test_another_plan_of_the_owner_is_left_alone(auth_client, plan_id, slug):
    other_slug = share(auth_client, answers_payload()).json()["slug"]
    answer(new_browser(), other_slug, name="Maya", swaps={TACOS: PIZZA})
    payload = answers_payload(plan_id)
    payload["stops"] = payload["stops"][:1]
    payload["legs"] = []
    share(auth_client, payload)
    assert ShareAnswer.objects.get().swaps == {TACOS: PIZZA}


# --- GV-10: stop sharing deletes the answers ------------------------------------------


def test_stop_sharing_deletes_the_answers(auth_client, slug):
    answer_as(slug, "Maya")
    answer_as(slug, "Jordan", status="out")
    assert auth_client.delete(f"/api/shares/{slug}/").status_code == 204
    assert ShareAnswer.objects.count() == 0


def test_after_stop_sharing_the_form_posts_to_a_missing_page(auth_client, browser, slug):
    auth_client.delete(f"/api/shares/{slug}/")
    response = answer(browser, slug)
    assert response.status_code == 404
    assert "This plan isn't shared anymore" in html(response)
    assert take_back(browser, slug).status_code == 404


# --- Only plans shared with answers on take answers ---------------------------------


def test_plans_shared_without_answers_show_no_form_and_refuse_answers(auth_client, browser):
    slug = share(auth_client, plan_payload()).json()["slug"]
    body = html(page(browser, slug))
    for text in ("I'm in", "Can't make it", "I'd swap this", "csrfmiddlewaretoken", "<form"):
        assert text not in body
    assert answer(browser, slug).status_code == 404
    assert take_back(browser, slug).status_code == 404
    assert ShareAnswer.objects.count() == 0


def test_answers_on_a_link_that_does_not_exist_are_404(browser):
    assert answer(browser, "doesnotexist").status_code == 404
    assert take_back(browser, "doesnotexist").status_code == 404


def test_the_answer_urls_only_take_posts(browser, slug):
    assert browser.get(f"/p/{slug}/answer").status_code == 405
    assert browser.get(f"/p/{slug}/answer/delete").status_code == 405


def test_a_plan_past_its_retention_takes_no_more_answers(auth_client, browser):
    long_ago = timezone.localdate() - timedelta(days=30)
    slug = share(auth_client, answers_payload(date=long_ago.isoformat())).json()["slug"]
    assert 'id="answer"' not in html(page(browser, slug))
    assert answer(browser, slug).status_code == 404
    assert ShareAnswer.objects.count() == 0


# --- GS-3: CSRF, headers and the policy ------------------------------------------------


def csrf_browser():
    return Client(enforce_csrf_checks=True)


def form_token(body):
    return re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', body).group(1)


def test_a_post_without_the_csrf_token_is_refused(slug):
    client = csrf_browser()
    assert answer(client, slug).status_code == 403
    page(client, slug)  # has the cookie now, but still no token in the form
    assert answer(client, slug).status_code == 403
    assert take_back(client, slug).status_code == 403
    assert ShareAnswer.objects.count() == 0


def test_a_post_with_the_pages_csrf_token_is_accepted(slug):
    client = csrf_browser()
    body = html(page(client, slug))
    token = form_token(body)
    response = client.post(f"/p/{slug}/answer", {"csrfmiddlewaretoken": token, "name": "Maya", "status": "in"})
    assert response.status_code == 303
    token = form_token(html(page(client, slug)))
    assert client.post(f"/p/{slug}/answer/delete", {"csrfmiddlewaretoken": token}).status_code == 303
    assert ShareAnswer.objects.count() == 0


def test_the_page_sends_its_origin_so_the_csrf_check_can_pass(slug):
    """Browsers send `Origin: null` on a form post from a page with `Referrer-Policy: no-referrer`,
    and Django refuses that origin. So pages that take answers use `same-origin`: the post carries
    the real origin, and other sites (fonts, maps) still get no referrer."""
    client = csrf_browser()
    response = page(client, slug)
    assert response["Referrer-Policy"] == "same-origin"
    token = form_token(html(response))
    data = {"csrfmiddlewaretoken": token, "name": "Maya", "status": "in"}
    assert client.post(f"/p/{slug}/answer", data, HTTP_ORIGIN="null").status_code == 403
    assert client.post(f"/p/{slug}/answer", data, HTTP_ORIGIN="https://evil.example").status_code == 403
    assert client.post(f"/p/{slug}/answer", data, HTTP_ORIGIN="http://testserver").status_code == 303


def test_a_page_that_takes_answers_is_never_cached(browser, slug):
    for response in (page(browser, slug), answer(browser, slug), answer(browser, slug, name="")):
        assert response["Cache-Control"] == "private, no-store", response.status_code
        assert response["X-Robots-Tag"] == "noindex, nofollow"
        assert response["Referrer-Policy"] == "same-origin"
        assert response["Content-Security-Policy"] == PUBLIC_PAGE_CSP


def test_the_page_with_the_form_fits_its_policy(browser, slug):
    answer(browser, slug, swaps={MET: MOMA})
    body = html(page(browser, slug))
    assert "<script" not in body and "<style" not in body and " style=" not in body
    assert not re.search(r"<[^>]+\son[a-z]+=", body)  # no inline event handlers
    forms = re.findall(r'<form[^>]*action="([^"]+)"', body)
    assert forms == [f"/p/{slug}/answer", f"/p/{slug}/answer/delete"]


def test_gv12_the_time_first_stop_and_cost_come_before_the_form(browser, slug):
    body = html(page(browser, slug))
    form = body.index('<form id="answer"')
    for text in ("11:00 AM – 6:15 PM", "The Met", "About $42 per person"):
        assert body.index(text) < form, text


# --- GS-2: 20 answers per address per hour, 50 per link ----------------------------------


@pytest.fixture
def clock(monkeypatch):
    now = {"t": 1_800_000_000.0 - 1_800_000_000.0 % 3600}
    monkeypatch.setattr(time, "time", lambda: now["t"])
    return now


def test_the_21st_answer_from_one_address_in_an_hour_is_refused(slug, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for n in range(20):
        response = answer(new_browser(), slug, name=f"Friend {'abcdefghijklmnopqrstu'[n]}", REMOTE_ADDR="203.0.113.7")
        assert response.status_code == 303, n

    refused = answer(new_browser(), slug, name="Late", REMOTE_ADDR="203.0.113.7")
    assert refused.status_code == 429
    assert "Too many answers right now. Please try again later." in html(refused)
    assert refused["Cache-Control"] == "private, no-store"
    assert "pa" not in refused.cookies
    assert ShareAnswer.objects.count() == 20
    assert answer(new_browser(), slug, name="Other", REMOTE_ADDR="198.51.100.4").status_code == 303

    clock["t"] += 3600
    assert answer(new_browser(), slug, name="Later", REMOTE_ADDR="203.0.113.7").status_code == 303


def test_changing_an_answer_counts_against_the_address_too(browser, slug, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for _ in range(20):
        assert answer(browser, slug, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert answer(browser, slug, status="out", REMOTE_ADDR="203.0.113.7").status_code == 429
    assert ShareAnswer.objects.get().status == "in"


def test_taking_back_an_answer_is_never_refused_by_the_limit(browser, slug, settings, clock):
    settings.BEHIND_TRUSTED_PROXY = False
    for _ in range(20):
        answer(browser, slug, REMOTE_ADDR="203.0.113.7")
    assert take_back(browser, slug, REMOTE_ADDR="203.0.113.7").status_code == 303
    assert ShareAnswer.objects.count() == 0


def fill_link(slug, count):
    shared = SharedPlan.objects.get(slug=slug)
    ShareAnswer.objects.bulk_create(
        ShareAnswer(
            shared_plan=shared,
            responder=hashlib.sha256(f"seed-{n}".encode()).hexdigest(),
            name=f"Seed {'abcdefghijklmnopqrstuvwxyz'[n % 26]}",
            status="in",
            plan_date=timezone.localdate(),
        )
        for n in range(count)
    )


def test_the_51st_answer_on_a_link_is_refused(browser, slug):
    answer(browser, slug, name="Maya")
    fill_link(slug, 49)
    assert ShareAnswer.objects.count() == 50

    refused = answer(new_browser(), slug, name="Late")
    assert refused.status_code == 429
    assert "Too many answers right now. Please try again later." in html(refused)
    assert ShareAnswer.objects.count() == 50
    # Someone who already answered can still change their answer.
    assert answer(browser, slug, name="Maya", status="out").status_code == 303
    assert ShareAnswer.objects.get(name="Maya").status == "out"


def test_the_cap_is_per_link(auth_client, slug):
    fill_link(slug, 50)
    other_slug = share(auth_client, answers_payload()).json()["slug"]
    assert answer(new_browser(), other_slug).status_code == 303


def test_the_owner_removing_answers_makes_room_again(auth_client, slug):
    fill_link(slug, 50)
    removed = ShareAnswer.objects.first()
    auth_client.delete(f"/api/shares/{slug}/answers/{removed.id}/")
    assert answer(new_browser(), slug).status_code == 303


# --- GS-5: answers are deleted 30 days after the plan's date ----------------------------


def test_answers_are_registered_for_expiry_30_days_after_the_plans_date():
    rules = [rule for rule in retention.RULES if rule.model is ShareAnswer]
    assert [(rule.date_field, rule.days) for rule in rules] == [("plan_date", 30)]


def test_purge_expired_deletes_expired_answers_and_nothing_else(slug):
    shared = SharedPlan.objects.get(slug=slug)
    now = datetime(2026, 12, 31, 12, tzinfo=UTC)
    for name, days in {"Old": 31, "Boundary": 30, "Recent": 29, "Upcoming": -3}.items():
        ShareAnswer.objects.create(
            shared_plan=shared,
            responder=hashlib.sha256(name.encode()).hexdigest(),
            name=name,
            status="in",
            plan_date=datetime(2026, 12, 31).date() - timedelta(days=days),
        )

    deleted = retention.purge_expired(now)
    assert deleted["shares.ShareAnswer.plan_date"] == 2
    assert sorted(ShareAnswer.objects.values_list("name", flat=True)) == ["Recent", "Upcoming"]
    assert SharedPlan.objects.filter(slug=slug).exists()  # the link is the organizer's; it stays


def test_answering_and_the_owner_list_purge_expired_answers(auth_client, slug):
    expired_slug = share(auth_client, answers_payload()).json()["slug"]

    def expire_one():
        fill_link(expired_slug, 1)
        ShareAnswer.objects.filter(shared_plan__slug=expired_slug).update(
            plan_date=timezone.localdate() - timedelta(days=31)
        )

    expire_one()
    answer_as(slug, "Maya")
    assert not ShareAnswer.objects.filter(shared_plan__slug=expired_slug).exists()

    expire_one()
    auth_client.get(f"/api/shares/{slug}/answers/")
    assert not ShareAnswer.objects.filter(shared_plan__slug=expired_slug).exists()


# --- GS-1: row level security on the new table -------------------------------------------


def test_the_answers_table_has_row_level_security():
    with connection.cursor() as cursor:
        cursor.execute("select relrowsecurity from pg_class where relname = 'shares_shareanswer'")
        assert cursor.fetchone() == (True,)
