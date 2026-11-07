import httpx
import pytest

from plandit.core.models import ActivityDay, ActivityEvent, AppSnapshot, DeletedAccount, Profile
from plandit.saved.models import SavedPost

pytestmark = pytest.mark.django_db

SERVICE_KEY = "service-role-key-for-tests"


USER_NOT_FOUND = {"code": 404, "error_code": "user_not_found", "msg": "User not found"}


class FakeDelete:
    """Stands in for httpx.delete. `outcome` is an int status or an exception to raise; `body`
    is the JSON (dict) or raw text the fake response carries."""

    def __init__(self, outcome, body=None):
        self.outcome = outcome
        self.body = body
        self.calls = []

    def __call__(self, url, *, headers, timeout):
        self.calls.append({"url": url, "headers": headers, "timeout": timeout})
        if isinstance(self.outcome, Exception):
            raise self.outcome
        request = httpx.Request("DELETE", url)
        if isinstance(self.body, dict | list):
            return httpx.Response(self.outcome, json=self.body, request=request)
        return httpx.Response(self.outcome, text=self.body or "", request=request)


@pytest.fixture
def service_key(settings):
    settings.SUPABASE_SERVICE_ROLE_KEY = SERVICE_KEY
    return SERVICE_KEY


@pytest.fixture
def fake_delete(monkeypatch):
    def install(outcome, body=None):
        fake = FakeDelete(outcome, body)
        monkeypatch.setattr(httpx, "delete", fake)
        return fake

    return install


@pytest.fixture
def populated(auth_client, user_id):
    """The user has a snapshot, an event, a saved post and an activity day (from the first request)."""
    assert (
        auth_client.put("/api/me/snapshot/", {"data": {"saved": [], "pastPlans": []}}, format="json").status_code == 200
    )
    assert auth_client.post("/api/me/events/", {"name": "link_saved"}, format="json").status_code == 201
    SavedPost.objects.create(owner_id=user_id, url="https://www.tiktok.com/@x/video/1")
    assert AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert ActivityDay.objects.filter(profile_id=user_id).exists()
    return user_id


def assert_all_data_present(user_id):
    assert Profile.objects.filter(id=user_id).exists()
    assert AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert ActivityEvent.objects.filter(profile_id=user_id).exists()
    assert ActivityDay.objects.filter(profile_id=user_id).exists()
    assert SavedPost.objects.filter(owner_id=user_id).exists()


def assert_all_data_gone(user_id):
    assert not Profile.objects.filter(id=user_id).exists()
    assert not AppSnapshot.objects.filter(profile_id=user_id).exists()
    assert not ActivityEvent.objects.filter(profile_id=user_id).exists()
    assert not ActivityDay.objects.filter(profile_id=user_id).exists()
    assert not SavedPost.objects.filter(owner_id=user_id).exists()


def test_delete_calls_supabase_then_removes_everything(auth_client, populated, service_key, fake_delete, settings):
    fake = fake_delete(200)
    response = auth_client.delete("/api/me/")
    assert response.status_code == 204
    assert_all_data_gone(populated)
    assert len(fake.calls) == 1
    call = fake.calls[0]
    assert call["url"] == f"{settings.SUPABASE_URL}/auth/v1/admin/users/{populated}"
    assert call["headers"] == {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}
    assert call["timeout"] == 10.0


@pytest.mark.parametrize(
    "body",
    [
        USER_NOT_FOUND,
        {"error_code": "user_not_found"},
        {"msg": "User not found"},
        {"message": "USER NOT FOUND"},
        {"code": 404, "message": "The user not found in the system"},
    ],
)
def test_supabase_404_for_a_missing_user_counts_as_success(auth_client, populated, service_key, fake_delete, body):
    fake_delete(404, body)
    assert auth_client.delete("/api/me/").status_code == 204
    assert_all_data_gone(populated)
    assert DeletedAccount.objects.filter(id=populated).exists()


@pytest.mark.parametrize(
    "body",
    [
        None,  # empty body
        "<html><body>404 Not Found</body></html>",  # proxy or wrong path
        "not json",
        {"error_code": "route_not_found", "msg": "No such route"},  # some other GoTrue 404
        {"message": "Not Found"},
        ["user_not_found"],  # JSON but not an object
    ],
)
def test_any_other_404_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete, body):
    fake_delete(404, body)
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)
    assert not DeletedAccount.objects.filter(id=populated).exists()


def test_supabase_error_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete):
    fake_delete(500)
    response = auth_client.delete("/api/me/")
    assert response.status_code == 502
    assert "detail" in response.json()
    assert_all_data_present(populated)


@pytest.mark.parametrize("status", [401, 403, 422])
def test_other_supabase_failures_are_502(auth_client, populated, service_key, fake_delete, status):
    fake_delete(status)
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)


def test_network_error_is_502_and_keeps_data(auth_client, populated, service_key, fake_delete):
    fake_delete(httpx.ConnectTimeout("timed out"))
    assert auth_client.delete("/api/me/").status_code == 502
    assert_all_data_present(populated)


def test_without_service_key_only_local_data_is_deleted(auth_client, populated, settings, fake_delete, caplog):
    settings.SUPABASE_SERVICE_ROLE_KEY = ""
    fake = fake_delete(200)
    with caplog.at_level("WARNING", logger="plandit.core.views"):
        assert auth_client.delete("/api/me/").status_code == 204
    assert fake.calls == []
    assert_all_data_gone(populated)
    assert any("SUPABASE_SERVICE_ROLE_KEY" in record.getMessage() for record in caplog.records)


def test_delete_only_touches_the_caller(auth_client, other_client, populated, service_key, fake_delete):
    fake_delete(200)
    assert other_client.put("/api/me/snapshot/", {"data": {"x": 1}}, format="json").status_code == 200
    assert auth_client.delete("/api/me/").status_code == 204
    assert other_client.get("/api/me/snapshot/").status_code == 200
    assert Profile.objects.count() == 1


def test_delete_requires_auth(api_client):
    assert api_client.delete("/api/me/").status_code == 401


# --- Tombstone: the access token stays valid until it expires ------------------------------


def test_deleted_account_token_is_rejected_and_nothing_comes_back(
    api_client, auth_client, populated, service_key, fake_delete, settings
):
    fake_delete(200)
    settings.METRICS_API_KEY = "k"
    signups_before = api_client.get("/api/metrics/", HTTP_X_METRICS_KEY="k").json()["totals"]["signups"]
    assert signups_before == 1

    assert auth_client.delete("/api/me/").status_code == 204
    assert DeletedAccount.objects.filter(id=populated).exists()

    response = auth_client.get("/api/me/")
    assert response.status_code == 401
    assert response.json()["detail"] == "Account deleted."
    assert auth_client.put("/api/me/snapshot/", {"data": {"saved": []}}, format="json").status_code == 401
    assert auth_client.post("/api/me/events/", {"name": "plan_built"}, format="json").status_code == 401
    assert not Profile.objects.filter(id=populated).exists()
    assert not AppSnapshot.objects.filter(profile_id=populated).exists()
    assert api_client.get("/api/metrics/", HTTP_X_METRICS_KEY="k").json()["totals"]["signups"] == 0


def test_failed_supabase_delete_writes_no_tombstone(auth_client, populated, service_key, fake_delete):
    fake_delete(500)
    assert auth_client.delete("/api/me/").status_code == 502
    assert not DeletedAccount.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/").status_code == 200


def test_without_service_key_no_tombstone_and_the_token_recreates_the_profile(
    auth_client, populated, settings, fake_delete
):
    # Documented: the Supabase auth user still exists, so that person must be able to come back.
    settings.SUPABASE_SERVICE_ROLE_KEY = ""
    fake_delete(200)
    assert auth_client.delete("/api/me/").status_code == 204
    assert not DeletedAccount.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/").status_code == 200
    assert Profile.objects.filter(id=populated).exists()
    assert auth_client.get("/api/me/snapshot/").status_code == 404  # fresh, empty account


def test_tombstone_does_not_affect_other_or_existing_profiles(
    auth_client, other_client, populated, service_key, fake_delete
):
    fake_delete(200)
    assert other_client.get("/api/me/").status_code == 200
    assert auth_client.delete("/api/me/").status_code == 204
    assert other_client.get("/api/me/").status_code == 200
    assert other_client.put("/api/me/snapshot/", {"data": {}}, format="json").status_code == 200


def test_tombstone_only_blocks_the_create_branch(auth_client, user_id, populated, django_assert_num_queries):
    # An existing profile with a stale tombstone (should not happen) keeps working: no extra query on the hot path.
    DeletedAccount.objects.create(id=user_id)
    with django_assert_num_queries(1):  # the profile lookup; claims and activity are already in sync
        assert auth_client.get("/api/me/").status_code == 200


# --- PATCH racing DELETE ------------------------------------------------------------------


def test_patch_that_loses_the_race_with_delete_does_not_resurrect_the_profile(auth_client, user_id, monkeypatch):
    """Simulate DELETE committing after PATCH authenticated but before it took the row lock: the
    last step before the lock is validation, so the tombstone + delete land there."""
    from plandit.core import views

    original_is_valid = views.ProfileSerializer.is_valid

    def delete_then_validate(self, *args, **kwargs):
        DeletedAccount.objects.create(id=user_id)
        Profile.objects.filter(pk=user_id).delete()
        return original_is_valid(self, *args, **kwargs)

    assert auth_client.get("/api/me/").status_code == 200
    monkeypatch.setattr(views.ProfileSerializer, "is_valid", delete_then_validate)

    response = auth_client.patch("/api/me/", {"school": "Columbia University"}, format="json")
    assert response.status_code == 401
    assert response.json()["detail"] == "Account deleted."
    assert not Profile.objects.filter(pk=user_id).exists()

    monkeypatch.undo()
    assert auth_client.get("/api/me/").status_code == 401  # the tombstone holds


def test_profile_serializer_update_never_inserts(profile):
    """Belt and braces under the lock: `save(update_fields=...)` raises instead of INSERTing when
    the row is gone, so even without the lock a PATCH could not bring a profile back."""
    from django.db import transaction

    from plandit.core.serializers import ProfileSerializer

    serializer = ProfileSerializer(profile, data={"school": "NYU"}, partial=True)
    assert serializer.is_valid()
    Profile.objects.filter(pk=profile.pk).delete()
    with pytest.raises(Profile.NotUpdated), transaction.atomic():
        serializer.save()
    assert not Profile.objects.filter(pk=profile.pk).exists()
