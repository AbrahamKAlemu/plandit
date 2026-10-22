import pytest

from plandit.waitlist.models import WaitlistSignup

pytestmark = pytest.mark.django_db


def test_signup_is_stored(api_client):
    response = api_client.post(
        "/api/waitlist/", {"email": "Someone@Example.com", "source": "plandit.app"}, format="json"
    )
    assert response.status_code == 201
    assert response.json() == {"ok": True}
    signup = WaitlistSignup.objects.get()
    assert signup.email == "someone@example.com"
    assert signup.source == "plandit.app"


def test_duplicate_signup_is_idempotent(api_client):
    api_client.post("/api/waitlist/", {"email": "a@example.com"}, format="json")
    response = api_client.post("/api/waitlist/", {"email": "A@example.com"}, format="json")
    assert response.status_code == 200
    assert WaitlistSignup.objects.count() == 1


def test_invalid_email_is_rejected(api_client):
    response = api_client.post("/api/waitlist/", {"email": "not-an-email"}, format="json")
    assert response.status_code == 400
    assert "email" in response.json()
    assert WaitlistSignup.objects.count() == 0


def test_signups_are_rate_limited(api_client):
    for i in range(3):
        assert api_client.post("/api/waitlist/", {"email": f"u{i}@example.com"}, format="json").status_code == 201
    assert api_client.post("/api/waitlist/", {"email": "u9@example.com"}, format="json").status_code == 429
