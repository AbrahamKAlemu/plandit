from unittest.mock import patch

import pytest

from plandit.saved.extraction import Metadata
from plandit.saved.models import SavedPost

pytestmark = pytest.mark.django_db

TIKTOK_URL = "https://www.tiktok.com/@uws.snacks/video/7400000000000000005"


def fake_metadata(title):
    return patch(
        "plandit.saved.extraction.OEmbedClient.metadata",
        return_value=Metadata(title=title, author_handle="@uws.snacks", thumbnail_url="https://img.example/t.jpg"),
    )


def test_saving_a_post_extracts_a_known_place(auth_client, profile, places):
    with fake_metadata("The Hungarian Pastry Shop lets you study for hours"):
        response = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json")
    assert response.status_code == 201
    body = response.json()
    assert body["platform"] == "tiktok"
    assert body["status"] == "ready"
    assert body["creator_handle"] == "@uws.snacks"
    assert body["place"]["name"] == "The Hungarian Pastry Shop"
    assert body["is_mappable"] is True


def test_unknown_place_marks_post_failed(auth_client, profile, places):
    with fake_metadata("POV: Sunday reset"):
        response = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json")
    assert response.status_code == 201
    assert response.json()["status"] == "failed"
    assert response.json()["place"] is None
    assert response.json()["failure_reason"]


def test_place_without_hours_needs_review(auth_client, profile, places):
    with fake_metadata("Late-night jazz at Smalls Jazz Club for the price of a drink"):
        response = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json")
    assert response.json()["status"] == "needs_review"
    assert response.json()["is_mappable"] is True


def test_shared_text_is_used_when_oembed_is_unavailable(auth_client, profile, places):
    response = auth_client.post(
        "/api/saved/",
        {
            "url": "https://www.instagram.com/reel/SAMPLE0002/",
            "shared_text": "NY students: The Met is pay-what-you-wish",
        },
        format="json",
    )
    assert response.status_code == 201
    assert response.json()["platform"] == "instagram"
    assert response.json()["place"]["name"] == "The Met"


def test_oembed_failure_does_not_crash(auth_client, profile, places):
    import httpx

    with patch("plandit.saved.extraction.OEmbedClient.metadata", side_effect=httpx.ConnectError("boom")):
        response = auth_client.post("/api/saved/", {"url": TIKTOK_URL, "shared_text": "Absolute Bagels"}, format="json")
    assert response.status_code == 201
    assert response.json()["place"]["name"] == "Absolute Bagels"


def test_saving_the_same_url_twice_returns_the_existing_post(auth_client, profile, places):
    with fake_metadata("Absolute Bagels"):
        first = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json")
        second = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json")
    assert first.status_code == 201
    assert second.status_code == 200
    assert first.json()["id"] == second.json()["id"]
    assert SavedPost.objects.count() == 1


def test_posts_are_private_to_their_owner(auth_client, other_client, profile, places):
    with fake_metadata("Absolute Bagels"):
        post_id = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json").json()["id"]
    assert other_client.get("/api/saved/").json() == []
    assert other_client.get(f"/api/saved/{post_id}/").status_code == 404
    assert other_client.delete(f"/api/saved/{post_id}/").status_code == 404


def test_user_can_pick_the_place_by_hand(auth_client, profile, places):
    with fake_metadata("POV: Sunday reset"):
        post_id = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json").json()["id"]
    response = auth_client.patch(
        f"/api/saved/{post_id}/", {"place_id": str(places["met"].id), "estimated_cost": 5}, format="json"
    )
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["place"]["name"] == "The Met"
    assert response.json()["estimated_cost"] == 5


def test_retry_runs_extraction_again(auth_client, profile, places):
    with fake_metadata("POV: Sunday reset"):
        post_id = auth_client.post("/api/saved/", {"url": TIKTOK_URL}, format="json").json()["id"]
    with fake_metadata("Absolute Bagels"):
        response = auth_client.post(f"/api/saved/{post_id}/retry/", format="json")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["place"]["name"] == "Absolute Bagels"


def test_rejects_non_http_urls(auth_client, profile):
    response = auth_client.post("/api/saved/", {"url": "javascript:alert(1)"}, format="json")
    assert response.status_code == 400
