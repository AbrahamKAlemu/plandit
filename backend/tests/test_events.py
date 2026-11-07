from datetime import UTC, datetime, timedelta

import pytest
from django.utils import timezone

from plandit.core.models import ActivityEvent, Profile
from plandit.core.views import EventsView

pytestmark = pytest.mark.django_db


def post(client, body):
    return client.post("/api/me/events/", body, format="json")


def parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def test_event_is_stored(auth_client, user_id):
    response = post(auth_client, {"name": "place_saved", "occurred_at": "2026-11-07T15:04:05Z"})
    assert response.status_code == 201
    body = response.json()
    assert body["name"] == "place_saved"
    assert set(body) == {"name", "occurred_at"}
    event = ActivityEvent.objects.get()
    assert event.profile_id == user_id
    assert event.name == "place_saved"
    assert parse(body["occurred_at"]) == event.occurred_at


def test_missing_occurred_at_means_now(auth_client):
    before = timezone.now()
    response = post(auth_client, {"name": "link_saved"})
    assert response.status_code == 201
    occurred_at = parse(response.json()["occurred_at"])
    assert before - timedelta(seconds=1) <= occurred_at <= timezone.now()


def test_unknown_name_is_400(auth_client):
    response = post(auth_client, {"name": "app_opened"})
    assert response.status_code == 400
    assert "name" in response.json()
    assert ActivityEvent.objects.count() == 0


def test_missing_name_is_400(auth_client):
    assert post(auth_client, {}).status_code == 400
    assert post(auth_client, {"occurred_at": "2026-11-07T15:04:05Z"}).status_code == 400


def test_garbage_occurred_at_is_400(auth_client):
    assert post(auth_client, {"name": "link_saved", "occurred_at": "yesterday"}).status_code == 400


def test_old_occurred_at_is_clamped_to_seven_days_ago(auth_client):
    before = timezone.now()
    long_ago = (before - timedelta(days=30)).isoformat()
    response = post(auth_client, {"name": "link_saved", "occurred_at": long_ago})
    assert response.status_code == 201
    occurred_at = parse(response.json()["occurred_at"])
    assert abs(occurred_at - (before - timedelta(days=7))) < timedelta(seconds=5)


def test_future_occurred_at_is_clamped_to_now(auth_client):
    future = (datetime.now(UTC) + timedelta(days=2)).isoformat()
    response = post(auth_client, {"name": "link_saved", "occurred_at": future})
    assert response.status_code == 201
    assert parse(response.json()["occurred_at"]) <= timezone.now()


def test_recent_occurred_at_is_kept(auth_client):
    an_hour_ago = (timezone.now() - timedelta(hours=1)).replace(microsecond=0)
    response = post(auth_client, {"name": "plan_built", "occurred_at": an_hour_ago.isoformat()})
    assert parse(response.json()["occurred_at"]) == an_hour_ago


def test_plan_built_activates_the_account_once(auth_client, user_id):
    assert post(auth_client, {"name": "place_saved"}).status_code == 201
    assert Profile.objects.get(id=user_id).activated_at is None

    assert post(auth_client, {"name": "plan_built"}).status_code == 201
    activated_at = Profile.objects.get(id=user_id).activated_at
    assert activated_at is not None

    assert post(auth_client, {"name": "plan_built"}).status_code == 201
    assert Profile.objects.get(id=user_id).activated_at == activated_at
    assert ActivityEvent.objects.filter(name="plan_built").count() == 2


def test_events_belong_to_the_caller(auth_client, other_client):
    post(auth_client, {"name": "link_saved"})
    post(other_client, {"name": "plan_built"})
    assert ActivityEvent.objects.values_list("profile_id", flat=True).distinct().count() == 2


def test_events_require_auth(api_client):
    assert post(api_client, {"name": "link_saved"}).status_code == 401


def test_events_use_the_events_throttle_scope(settings):
    assert EventsView.throttle_scope == "events"
    assert "events" in settings.REST_FRAMEWORK["DEFAULT_THROTTLE_RATES"]
