import re
import uuid
from datetime import timedelta

import pytest
from django.contrib.staticfiles import finders
from django.utils import timezone

from plandit.core.models import Profile
from plandit.shares.models import SharedPlan

pytestmark = pytest.mark.django_db


def plan_payload(plan_id=None, **overrides):
    payload = {
        "planId": str(plan_id or uuid.uuid4()),
        "title": "Morningside to the Village",
        "dateText": "Saturday, November 22",
        "timeText": "11:00 AM – 6:15 PM",
        "note": "Who's in?",
        "costText": "About $42 per person",
        "stops": [
            {
                "name": "The Met",
                "place": "Culture · Upper East Side",
                "address": "1000 Fifth Ave",
                "timeText": "11:00 AM",
                "durationText": "2 hr",
                "costText": "$5",
                "latitude": 40.7794,
                "longitude": -73.9632,
            },
            {"name": "Los Tacos No. 1", "timeText": "2:45 PM", "address": "75 Ninth Ave"},
        ],
        "legs": [{"text": "35 min subway (4 and 7 trains, $2.90)"}],
    }
    payload.update(overrides)
    return payload


def share(client, payload):
    return client.post("/api/shares/", payload, format="json")


def test_sharing_a_plan_returns_a_link(auth_client):
    response = share(auth_client, plan_payload())
    assert response.status_code == 201
    body = response.json()
    assert len(body["slug"]) == 10
    assert body["url"] == f"http://testserver/p/{body['slug']}"
    shared = SharedPlan.objects.get()
    assert shared.data["title"] == "Morningside to the Village"
    assert "planId" not in shared.data


def test_sharing_the_same_plan_again_updates_the_same_link(auth_client):
    plan_id = uuid.uuid4()
    first = share(auth_client, plan_payload(plan_id)).json()
    second = share(auth_client, plan_payload(plan_id, title="Changed my mind"))
    assert second.status_code == 200
    assert second.json()["slug"] == first["slug"]
    assert SharedPlan.objects.count() == 1
    assert SharedPlan.objects.get().data["title"] == "Changed my mind"


def test_two_people_sharing_the_same_plan_id_get_their_own_links(auth_client, other_client):
    plan_id = uuid.uuid4()
    a = share(auth_client, plan_payload(plan_id)).json()["slug"]
    b = share(other_client, plan_payload(plan_id)).json()["slug"]
    assert a != b


def test_sharing_needs_an_account(api_client):
    assert share(api_client, plan_payload()).status_code in (401, 403)
    assert SharedPlan.objects.count() == 0


@pytest.mark.parametrize(
    "overrides",
    [
        {"stops": []},
        {"title": "x" * 121},
        {"legs": [{"text": "walk"}, {"text": "walk"}]},
        {"planId": "not-a-uuid"},
        {"stops": [{"name": "No time"}]},
    ],
)
def test_bad_plans_are_rejected(auth_client, overrides):
    assert share(auth_client, plan_payload(**overrides)).status_code == 400
    assert SharedPlan.objects.count() == 0


def test_the_page_shows_the_plan_to_anyone(auth_client, api_client):
    slug = share(auth_client, plan_payload()).json()["slug"]
    response = api_client.get(f"/p/{slug}")
    assert response.status_code == 200
    html = response.content.decode()
    for text in [
        "Morningside to the Village",
        "Saturday, November 22",
        "11:00 AM – 6:15 PM",
        "About $42 per person",
        "Who&#x27;s in?",
        "The Met",
        "Culture · Upper East Side",
        "35 min subway (4 and 7 trains, $2.90)",
        "Los Tacos No. 1",
        "https://maps.apple.com/?q=The+Met&amp;ll=40.7794%2C-73.9632",
        "https://maps.apple.com/?q=Los+Tacos+No.+1&amp;address=75+Ninth+Ave",
    ]:
        assert text in html, text
    # Link previews (iMessage, WhatsApp) read these.
    assert '<meta property="og:title" content="Morningside to the Village">' in html
    assert "Saturday, November 22 · 2 stops: The Met, Los Tacos No. 1" in html
    assert response["X-Robots-Tag"] == "noindex, nofollow"


def test_the_page_escapes_what_people_type(auth_client, api_client):
    slug = share(auth_client, plan_payload(title="<script>alert(1)</script>", note='"><img src=x>')).json()["slug"]
    html = api_client.get(f"/p/{slug}").content.decode()
    assert "<script>alert(1)</script>" not in html
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html
    assert '"><img src=x>' not in html


def test_stopping_sharing_takes_the_page_down(auth_client, api_client):
    slug = share(auth_client, plan_payload()).json()["slug"]
    assert auth_client.delete(f"/api/shares/{slug}/").status_code == 204
    response = api_client.get(f"/p/{slug}")
    assert response.status_code == 404
    assert "This plan isn't shared anymore" in response.content.decode()


def test_only_the_owner_can_stop_sharing(auth_client, other_client, api_client):
    slug = share(auth_client, plan_payload()).json()["slug"]
    assert other_client.delete(f"/api/shares/{slug}/").status_code == 404
    assert api_client.get(f"/p/{slug}").status_code == 200


def test_unknown_links_are_not_found(api_client):
    assert api_client.get("/p/doesnotexist").status_code == 404


def test_deleting_the_account_deletes_its_links(auth_client, user_id, api_client):
    slug = share(auth_client, plan_payload()).json()["slug"]
    Profile.objects.filter(id=user_id).delete()
    assert api_client.get(f"/p/{slug}").status_code == 404


def test_links_use_the_site_address_once_configured(auth_client, settings):
    settings.SHARE_BASE_URL = "https://plandit.app"
    body = share(auth_client, plan_payload()).json()
    assert body["url"] == f"https://plandit.app/p/{body['slug']}"


PUBLIC_PAGE_CSP = (
    "default-src 'none'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
    "img-src 'self' data: https://plandit.app https://www.plandit.app; "
    "form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
)


def test_the_page_has_a_content_security_policy(auth_client, api_client):
    slug = share(auth_client, plan_payload()).json()["slug"]
    assert api_client.get(f"/p/{slug}")["Content-Security-Policy"] == PUBLIC_PAGE_CSP
    assert api_client.get("/p/doesnotexist")["Content-Security-Policy"] == PUBLIC_PAGE_CSP


def test_the_api_has_no_page_policy(api_client):
    assert "Content-Security-Policy" not in api_client.get("/api/health/")


@pytest.mark.parametrize("found", [True, False])
def test_the_page_fits_its_policy(auth_client, api_client, found):
    """No inline styles or scripts (the policy would block them); stylesheets are the app's own
    static files, plus the Google font."""
    slug = share(auth_client, plan_payload()).json()["slug"] if found else "doesnotexist"
    html = api_client.get(f"/p/{slug}").content.decode()
    assert "<style" not in html
    assert "<script" not in html
    assert " style=" not in html
    stylesheets = re.findall(r'<link rel="stylesheet" href="([^"]+)">', html)
    assert stylesheets[0].startswith("https://fonts.googleapis.com/")
    assert len(stylesheets) == 3
    for href in stylesheets[1:]:
        assert href.startswith("/static/shares/")
        assert finders.find(href.removeprefix("/static/")), href
    for src in re.findall(r'<img[^>]* src="([^"]+)"', html):
        assert src.startswith("https://plandit.app/"), src


@pytest.mark.parametrize("found", [True, False])
def test_every_page_has_a_report_link(auth_client, api_client, found):
    slug = share(auth_client, plan_payload()).json()["slug"] if found else "doesnotexist"
    html = api_client.get(f"/p/{slug}").content.decode()
    link = re.search(r'<a href="(mailto:support@plandit\.app[^"]*)">Report this page</a>', html)
    assert link, "no report link"
    if found:
        assert f"%2Fp%2F{slug}" in link.group(1)


# --- Group plans, slice G1a: optional fields for answers on the page ------------------------

STOP_ID = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
OTHER_STOP_ID = "0A1B2C3D-4E5F-4A6B-8C7D-8E9F0A1B2C3D"
MOMA = {"id": "11111111-2222-4333-8444-555555555555", "name": "MoMA"}
GUGGENHEIM = {"id": "22222222-3333-4444-8555-666666666666", "name": "The Guggenheim"}
PIZZA = {"id": "33333333-4444-4555-8666-777777777777", "name": "Prince Street Pizza"}


def tomorrow():
    return (timezone.localdate() + timedelta(days=1)).isoformat()


def answers_payload():
    payload = plan_payload(answers=True, date=tomorrow())
    payload["stops"][0].update(id=STOP_ID, alternates=[dict(MOMA), dict(GUGGENHEIM)])
    payload["stops"][1].update(id=OTHER_STOP_ID)
    return payload


def test_old_payloads_keep_working_unchanged(auth_client, api_client):
    """Today's app sends none of the new fields: the stored plan and the page are what they were."""
    response = share(auth_client, plan_payload())
    assert response.status_code == 201
    stored = SharedPlan.objects.get().data
    assert set(stored) == {"title", "dateText", "timeText", "note", "costText", "stops", "legs"}
    for stop in stored["stops"]:
        assert set(stop) == {
            "name",
            "place",
            "address",
            "timeText",
            "durationText",
            "costText",
            "latitude",
            "longitude",
        }

    page = api_client.get(f"/p/{response.json()['slug']}")
    assert page["Cache-Control"] == "public, max-age=60"
    assert page["Referrer-Policy"] == "no-referrer"
    assert "csrftoken" not in page.cookies and "pa" not in page.cookies
    html = page.content.decode()
    assert "<form" not in html and "I'm in" not in html and 'class="going"' not in html


def test_the_new_fields_are_stored_as_sent(auth_client):
    payload = answers_payload()
    payload["stops"][0]["alternates"][0].update(neighborhood="Midtown", kind="Culture", costText="$30")
    response = share(auth_client, payload)
    assert response.status_code == 201, response.json()
    stored = SharedPlan.objects.get().data
    assert stored["answers"] is True
    assert stored["date"] == tomorrow()
    assert stored["stops"][0]["id"] == STOP_ID  # exactly as sent, upper case included
    assert stored["stops"][0]["alternates"] == [
        {"id": MOMA["id"], "name": "MoMA", "neighborhood": "Midtown", "kind": "Culture", "costText": "$30"},
        {"id": GUGGENHEIM["id"], "name": "The Guggenheim", "neighborhood": "", "kind": "", "costText": ""},
    ]
    assert stored["stops"][1]["id"] == OTHER_STOP_ID and "alternates" not in stored["stops"][1]


@pytest.mark.parametrize(
    "change",
    [
        pytest.param(lambda p: p.update(answers=False), id="answers-off-with-a-date"),
        pytest.param(lambda p: p.update(answers=False) or p.pop("date"), id="answers-off-without-a-date"),
        pytest.param(lambda p: p.update(date="2025-01-31"), id="a-past-date"),
        pytest.param(lambda p: p["stops"][0].update(alternates=[]), id="no-alternates"),
        pytest.param(lambda p: p["stops"][0].update(id=STOP_ID.lower()), id="lower-case-id"),
        pytest.param(lambda p: p.update(stops=plan_payload()["stops"]), id="answers-on-without-stop-ids"),
    ],
)
def test_optional_field_combinations_are_accepted(auth_client, change):
    payload = answers_payload()
    change(payload)
    response = share(auth_client, payload)
    assert response.status_code == 201, response.json()


def too_far_ahead():
    return (timezone.localdate() + timedelta(days=367)).isoformat()


@pytest.mark.parametrize(
    "change",
    [
        pytest.param(lambda p: p.update(answers="yes"), id="answers-a-string"),
        pytest.param(lambda p: p.update(answers=1), id="answers-a-number"),
        pytest.param(lambda p: p.update(answers=None), id="answers-null"),
        pytest.param(lambda p: p.pop("date"), id="answers-without-a-date"),
        pytest.param(lambda p: p.update(date="2026-11-22T10:00:00"), id="date-with-a-time"),
        pytest.param(lambda p: p.update(date="20261122"), id="date-compact"),
        pytest.param(lambda p: p.update(date="2026-W47-6"), id="date-iso-week"),
        pytest.param(lambda p: p.update(date="2026-02-30"), id="date-impossible"),
        pytest.param(lambda p: p.update(date="next Saturday"), id="date-words"),
        pytest.param(lambda p: p.update(date=20261122), id="date-a-number"),
        pytest.param(lambda p: p.update(date=too_far_ahead()), id="date-over-a-year-ahead"),
        pytest.param(lambda p: p["stops"][0].update(id="not-a-uuid"), id="stop-id-not-a-uuid"),
        pytest.param(lambda p: p["stops"][0].update(id=f"{{{STOP_ID}}}"), id="stop-id-braces"),
        pytest.param(lambda p: p["stops"][0].update(id=""), id="stop-id-empty"),
        pytest.param(lambda p: p["stops"][0].update(id=12345), id="stop-id-a-number"),
        pytest.param(lambda p: p["stops"][1].update(id=STOP_ID), id="stop-ids-repeated"),
        pytest.param(lambda p: p["stops"][1].update(id=STOP_ID.lower()), id="stop-ids-repeated-in-another-case"),
        pytest.param(lambda p: p["stops"][0].pop("id"), id="alternates-without-a-stop-id"),
        pytest.param(lambda p: p["stops"][0]["alternates"].append(dict(PIZZA)), id="three-alternates"),
        pytest.param(lambda p: p["stops"][0].update(alternates=[dict(MOMA), dict(MOMA)]), id="alternate-repeated"),
        pytest.param(lambda p: p["stops"][0].update(alternates=None), id="alternates-null"),
        pytest.param(lambda p: p["stops"][0].update(alternates="MoMA"), id="alternates-not-a-list"),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].pop("id"), id="alternate-without-an-id"),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].update(id="moma"), id="alternate-id-not-a-uuid"),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].pop("name"), id="alternate-without-a-name"),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].update(name="x" * 121), id="alternate-name-too-long"),
        pytest.param(
            lambda p: p["stops"][0]["alternates"][0].update(neighborhood="x" * 81), id="neighborhood-too-long"
        ),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].update(kind="x" * 41), id="kind-too-long"),
        pytest.param(lambda p: p["stops"][0]["alternates"][0].update(costText="x" * 41), id="cost-too-long"),
    ],
)
def test_bad_new_fields_are_rejected(auth_client, change):
    payload = answers_payload()
    change(payload)
    assert share(auth_client, payload).status_code == 400
    assert SharedPlan.objects.count() == 0
