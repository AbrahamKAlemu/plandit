import uuid

import pytest

from plandit.core.models import Profile
from tests.conftest import make_token

pytestmark = pytest.mark.django_db


def test_health_is_public(api_client):
    response = api_client.get("/api/health/")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_me_requires_bearer_token(api_client):
    response = api_client.get("/api/me/")
    assert response.status_code == 401
    assert response["WWW-Authenticate"].startswith("Bearer")


def test_garbage_token_is_rejected(api_client):
    api_client.credentials(HTTP_AUTHORIZATION="Bearer not-a-jwt")
    assert api_client.get("/api/me/").status_code == 401


def test_expired_token_is_rejected(api_client):
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {make_token(expires_in=-10)}")
    response = api_client.get("/api/me/")
    assert response.status_code == 401
    assert response.json()["detail"] == "Token has expired."


def test_wrong_audience_is_rejected(api_client):
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {make_token(aud='anon')}")
    assert api_client.get("/api/me/").status_code == 401


def test_wrong_secret_is_rejected(api_client, settings):
    token = make_token()
    settings.SUPABASE_JWT_SECRET = "a-different-secret-that-is-also-32-bytes-long"
    api_client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    assert api_client.get("/api/me/").status_code == 401


def test_first_request_creates_profile_from_claims(api_client):
    user_id = uuid.uuid4()
    api_client.credentials(
        HTTP_AUTHORIZATION=f"Bearer {make_token(user_id, email='new@columbia.edu', name='New Student')}"
    )
    response = api_client.get("/api/me/")
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(user_id)
    assert body["email"] == "new@columbia.edu"
    assert body["name"] == "New Student"
    assert body["default_budget"] == 60
    assert Profile.objects.filter(id=user_id).exists()


def test_profile_can_be_updated(auth_client):
    response = auth_client.patch(
        "/api/me/",
        {"school": "Columbia University", "home_base": "Morningside Heights", "default_budget": 45},
        format="json",
    )
    assert response.status_code == 200
    assert response.json()["school"] == "Columbia University"
    assert response.json()["default_budget"] == 45


def test_email_is_read_only(auth_client):
    response = auth_client.patch("/api/me/", {"email": "hacker@example.com"}, format="json")
    assert response.status_code == 200
    assert response.json()["email"] == "student@columbia.edu"
