import importlib
import uuid
from datetime import datetime, timedelta

import pytest
from django.apps import apps
from django.utils import timezone
from rest_framework.test import APIClient

from plandit.core.activity import ACTIVITY_INTERVAL, record_activity, sync_claims
from plandit.core.models import ActivityDay, Profile
from tests.conftest import make_token

pytestmark = pytest.mark.django_db


def client_for(token: str) -> APIClient:
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    return client


# --- Activity ----------------------------------------------------------------------------


def test_first_request_records_last_seen_and_activity_day(auth_client, user_id):
    before = timezone.now()
    assert auth_client.get("/api/me/").status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.last_seen_at is not None
    assert profile.last_seen_at >= before
    assert list(ActivityDay.objects.filter(profile=profile).values_list("date", flat=True)) == [timezone.localdate()]


def test_second_request_within_five_minutes_does_not_write(auth_client, user_id):
    auth_client.get("/api/me/")
    first = Profile.objects.get(id=user_id).last_seen_at
    for _ in range(3):
        assert auth_client.get("/api/me/stats/").status_code == 200
    assert Profile.objects.get(id=user_id).last_seen_at == first
    assert ActivityDay.objects.filter(profile_id=user_id).count() == 1


def test_request_after_five_minutes_updates_last_seen(auth_client, user_id):
    auth_client.get("/api/me/")
    stale = timezone.now() - ACTIVITY_INTERVAL - timedelta(seconds=1)
    Profile.objects.filter(id=user_id).update(last_seen_at=stale)
    auth_client.get("/api/me/")
    assert Profile.objects.get(id=user_id).last_seen_at > stale
    assert ActivityDay.objects.filter(profile_id=user_id).count() == 1  # same day, still one row


def test_record_activity_writes_on_a_new_local_day(profile):
    tz = timezone.get_current_timezone()
    late_last_night = timezone.make_aware(datetime(2026, 11, 6, 23, 59, 30), tz)
    just_after_midnight = timezone.make_aware(datetime(2026, 11, 7, 0, 0, 30), tz)
    assert record_activity(profile, now=late_last_night) is True
    # One minute later but a new local date: writes again even though it is inside the interval.
    assert record_activity(profile, now=just_after_midnight) is True
    assert profile.last_seen_at == just_after_midnight
    assert sorted(ActivityDay.objects.filter(profile=profile).values_list("date", flat=True)) == [
        late_last_night.date(),
        just_after_midnight.date(),
    ]
    # Same day, inside the interval: nothing.
    assert record_activity(profile, now=just_after_midnight + timedelta(minutes=2)) is False


def test_record_activity_tolerates_an_existing_day_row(profile):
    now = timezone.now()
    ActivityDay.objects.create(profile=profile, date=timezone.localdate(now))
    assert record_activity(profile, now=now) is True
    assert ActivityDay.objects.filter(profile=profile).count() == 1


def test_anonymous_profiles_still_get_activity_rows():
    user_id = uuid.uuid4()
    client = client_for(make_token(user_id, email="", name="", is_anonymous=True))
    assert client.get("/api/me/").status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.is_anonymous is True
    assert profile.last_seen_at is not None
    assert ActivityDay.objects.filter(profile=profile).count() == 1


# --- Claim syncing -----------------------------------------------------------------------


def test_new_email_account_is_a_signup():
    user_id = uuid.uuid4()
    before = timezone.now()
    client = client_for(make_token(user_id))
    assert client.get("/api/me/").status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.is_anonymous is False
    assert profile.auth_provider == "email"
    assert profile.signed_up_at is not None
    assert profile.signed_up_at >= before
    assert profile.activated_at is None


def test_apple_provider_is_recorded():
    user_id = uuid.uuid4()
    token = make_token(user_id, email="hidden@privaterelay.appleid.com", app_metadata={"provider": "apple"})
    assert client_for(token).get("/api/me/").status_code == 200
    assert Profile.objects.get(id=user_id).auth_provider == "apple"


def test_anonymous_token_is_not_a_signup():
    user_id = uuid.uuid4()
    client = client_for(make_token(user_id, email="", name="", is_anonymous=True))
    assert client.get("/api/me/").status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.is_anonymous is True
    assert profile.signed_up_at is None
    assert profile.auth_provider == ""


def test_anonymous_session_converting_to_an_account_becomes_a_signup():
    user_id = uuid.uuid4()
    client_for(make_token(user_id, email="", name="", is_anonymous=True)).get("/api/me/")
    assert Profile.objects.get(id=user_id).signed_up_at is None

    before = timezone.now()
    client_for(make_token(user_id, email="now@columbia.edu")).get("/api/me/")
    profile = Profile.objects.get(id=user_id)
    assert profile.is_anonymous is False
    assert profile.auth_provider == "email"
    assert profile.email == "now@columbia.edu"
    assert profile.signed_up_at is not None and profile.signed_up_at >= before


def test_signed_up_at_is_set_once(auth_client, user_id):
    auth_client.get("/api/me/")
    first = Profile.objects.get(id=user_id).signed_up_at
    assert first is not None
    auth_client.get("/api/me/")
    assert Profile.objects.get(id=user_id).signed_up_at == first


def test_sync_claims_writes_only_when_something_changed(profile):
    claims = {"is_anonymous": False, "app_metadata": {"provider": "email"}}
    assert sync_claims(profile, claims) is True  # signed_up_at and provider were empty
    assert sync_claims(profile, claims) is False
    assert sync_claims(profile, {"is_anonymous": False, "app_metadata": {"provider": "apple"}}) is True
    assert Profile.objects.get(id=profile.id).auth_provider == "apple"


def test_existing_profile_gets_claim_fields_on_next_request(profile, auth_client):
    # `profile` was created directly (pre-accounts shape): no provider, no signed_up_at.
    assert profile.signed_up_at is None
    auth_client.get("/api/me/")
    profile.refresh_from_db()
    assert profile.is_anonymous is False
    assert profile.auth_provider == "email"
    assert profile.signed_up_at is not None


# --- Data migration ----------------------------------------------------------------------


def test_backfill_marks_emailless_profiles_anonymous_and_dates_the_rest():
    backfill = importlib.import_module("plandit.core.migrations.0004_backfill_signups").backfill
    anon = Profile.objects.create(id=uuid.uuid4(), email="")
    real = Profile.objects.create(id=uuid.uuid4(), email="old@columbia.edu")
    already = Profile.objects.create(
        id=uuid.uuid4(), email="new@columbia.edu", signed_up_at=timezone.now() - timedelta(days=3)
    )
    already_signed_up_at = already.signed_up_at

    backfill(apps, None)

    anon.refresh_from_db()
    real.refresh_from_db()
    already.refresh_from_db()
    assert anon.is_anonymous is True and anon.signed_up_at is None
    assert real.is_anonymous is False and real.signed_up_at == real.created_at
    assert already.is_anonymous is False and already.signed_up_at == already_signed_up_at


def test_is_anonymous_is_one_way():
    user_id = uuid.uuid4()
    client_for(make_token(user_id, email="real@columbia.edu")).get("/api/me/")
    signed_up_at = Profile.objects.get(id=user_id).signed_up_at
    assert signed_up_at is not None

    # A later anonymous token for the same sub (stale device, odd client) never demotes the signup.
    assert client_for(make_token(user_id, email="", name="", is_anonymous=True)).get("/api/me/").status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.is_anonymous is False
    assert profile.signed_up_at == signed_up_at
    assert profile.email == "real@columbia.edu"
    assert profile.auth_provider == "email"


def test_sync_claims_never_sets_anonymous_on_an_existing_profile(profile):
    assert profile.is_anonymous is False
    assert sync_claims(profile, {"is_anonymous": True, "app_metadata": {}}) is False
    assert Profile.objects.get(id=profile.id).is_anonymous is False


# --- Token subject -------------------------------------------------------------------------


@pytest.mark.parametrize("sub", ["not-a-uuid", "12345", "", None, 42])
def test_non_uuid_subject_is_401_not_500(sub):
    response = client_for(make_token(sub=sub)).get("/api/me/")
    assert response.status_code == 401
    assert Profile.objects.count() == 0
