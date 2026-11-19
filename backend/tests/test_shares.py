import uuid

import pytest

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
