import pytest

pytestmark = pytest.mark.django_db


def test_places_require_auth(api_client, places):
    assert api_client.get("/api/places/").status_code == 401


def test_places_can_be_searched(auth_client, profile, places):
    response = auth_client.get("/api/places/", {"q": "bagel"})
    assert response.status_code == 200
    assert [p["name"] for p in response.json()] == ["Absolute Bagels"]

    response = auth_client.get("/api/places/", {"category": "culture"})
    assert [p["name"] for p in response.json()] == ["The Met"]

    response = auth_client.get(f"/api/places/{places['smalls'].id}/")
    assert response.json()["hours"] is None


def test_fixture_loads(django_db_blocker):
    from django.core.management import call_command

    from plandit.places.models import Place

    with django_db_blocker.unblock():
        call_command("loaddata", "manhattan_places", verbosity=0)
        assert Place.objects.count() == 22
        assert Place.objects.get(name="Levain Bakery").neighborhood == "Upper West Side"
