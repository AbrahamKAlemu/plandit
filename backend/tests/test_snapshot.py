import json
from decimal import Decimal

import pytest

from plandit.core.models import AppSnapshot, Profile

pytestmark = pytest.mark.django_db

SNAPSHOT = {
    "saved": [
        {
            "id": "A1B2",
            "url": "https://www.tiktok.com/@x/video/1",
            "savedAt": "2026-11-01T14:03:00Z",
            "tags": ["coffee"],
        }
    ],
    "today": {"date": "2026-11-07", "budget": 40.5, "stops": [], "legs": []},
    "profile": {
        "name": "Abraham",
        "school": "Columbia University",
        "homeBase": "Morningside Heights",
        "defaultBudget": 45.0,
        "travelModes": "Walk only",
    },
    "pastPlans": [],
    "visited": [],
}


def put(client, data):
    return client.put("/api/me/snapshot/", {"data": data}, format="json")


def test_get_before_any_put_is_404(auth_client):
    response = auth_client.get("/api/me/snapshot/")
    assert response.status_code == 404
    assert response.json() == {"detail": "No snapshot yet."}


def test_put_then_get_round_trips_the_json_unchanged(auth_client):
    response = put(auth_client, SNAPSHOT)
    assert response.status_code == 200
    body = response.json()
    assert body["version"] == 1
    assert body["updated_at"].endswith("Z")
    assert set(body) == {"version", "updated_at"}

    response = auth_client.get("/api/me/snapshot/")
    assert response.status_code == 200
    body = response.json()
    assert body["version"] == 1
    assert body["data"] == SNAPSHOT
    # camelCase keys and ISO strings survive untouched; nothing is renamed to snake_case.
    assert json.dumps(body["data"], sort_keys=True) == json.dumps(SNAPSHOT, sort_keys=True)


def test_version_increments_on_every_put(auth_client):
    assert put(auth_client, SNAPSHOT).json()["version"] == 1
    assert put(auth_client, {**SNAPSHOT, "visited": [{"id": "p1"}]}).json()["version"] == 2
    assert put(auth_client, SNAPSHOT).json()["version"] == 3
    assert auth_client.get("/api/me/snapshot/").json()["version"] == 3
    assert AppSnapshot.objects.count() == 1


def test_oversize_snapshot_is_413_and_not_stored(auth_client):
    response = put(auth_client, {"blob": "x" * 1_000_001})
    assert response.status_code == 413
    assert AppSnapshot.objects.count() == 0
    assert auth_client.get("/api/me/snapshot/").status_code == 404


def test_snapshot_just_under_the_limit_is_accepted(auth_client):
    # {"blob":"xxx..."} is 11 bytes of framing plus the string.
    response = put(auth_client, {"blob": "x" * (1_000_000 - 11)})
    assert response.status_code == 200


@pytest.mark.parametrize(
    "body",
    [
        {"data": [1, 2, 3]},
        {"data": "string"},
        {"data": None},
        {"data": 7},
        {},
        [{"data": {}}],
        "nope",
    ],
)
def test_non_object_data_is_400(auth_client, body):
    response = auth_client.put("/api/me/snapshot/", body, format="json")
    assert response.status_code == 400
    assert AppSnapshot.objects.count() == 0


def test_profile_fields_are_mirrored(auth_client, profile):
    assert put(auth_client, SNAPSHOT).status_code == 200
    profile.refresh_from_db()
    assert profile.name == "Abraham"
    assert profile.school == "Columbia University"
    assert profile.home_base == "Morningside Heights"
    assert profile.default_budget == Decimal("45.00")
    assert profile.travel_modes == "Walk only"
    # /api/me/ sees the same values.
    me = auth_client.get("/api/me/").json()
    assert me["school"] == "Columbia University"
    assert me["default_budget"] == 45


def test_bad_profile_values_are_ignored_not_rejected(auth_client, profile):
    data = {
        **SNAPSHOT,
        "profile": {
            "name": 42,  # wrong type
            "school": "x" * 500,  # too long, truncated
            "homeBase": None,
            "defaultBudget": 99_999,  # out of range
            "travelModes": True,
        },
    }
    assert put(auth_client, data).status_code == 200
    profile.refresh_from_db()
    assert profile.name == "Abraham"  # unchanged
    assert profile.school == "x" * 120
    assert profile.home_base == ""
    assert profile.default_budget == Decimal("60.00")
    assert profile.travel_modes == "Walk + subway"


@pytest.mark.parametrize("bad_profile", [None, "str", [], 3])
def test_missing_or_malformed_profile_block_is_fine(auth_client, profile, bad_profile):
    data = {**SNAPSHOT, "profile": bad_profile}
    assert put(auth_client, data).status_code == 200
    profile.refresh_from_db()
    assert profile.name == "Abraham"


def test_counters_are_recorded(auth_client, user_id):
    data = {
        **SNAPSHOT,
        "saved": [{"id": "1"}, {"id": "2"}, {"id": "3"}],
        "pastPlans": [{"id": "p"}],
        "today": {"stops": [{"id": "s1"}, {"id": "s2"}]},
    }
    assert put(auth_client, data).status_code == 200
    snapshot = AppSnapshot.objects.get(profile_id=user_id)
    assert (snapshot.saved_count, snapshot.past_plans_count, snapshot.today_stop_count) == (3, 1, 2)


def test_counters_tolerate_wrong_shapes(auth_client, user_id):
    data = {"saved": "nope", "pastPlans": None, "today": "not a dict"}
    assert put(auth_client, data).status_code == 200
    snapshot = AppSnapshot.objects.get(profile_id=user_id)
    assert (snapshot.saved_count, snapshot.past_plans_count, snapshot.today_stop_count) == (0, 0, 0)


def test_snapshot_with_a_planned_stop_activates_the_account(auth_client, user_id):
    assert put(auth_client, SNAPSHOT).status_code == 200
    assert Profile.objects.get(id=user_id).activated_at is None

    with_stop = {**SNAPSHOT, "today": {**SNAPSHOT["today"], "stops": [{"id": "s1", "placeId": "p1"}]}}
    assert put(auth_client, with_stop).status_code == 200
    activated_at = Profile.objects.get(id=user_id).activated_at
    assert activated_at is not None

    # Already activated: a later empty snapshot does not clear or move it.
    assert put(auth_client, SNAPSHOT).status_code == 200
    assert Profile.objects.get(id=user_id).activated_at == activated_at


PAST_PLAN = {"id": "p1", "title": "Saturday", "date": "2026-10-31", "stopCount": 2, "cost": 31.5, "walkingMiles": 1.2}


def test_past_plan_with_stops_activates_the_account(auth_client, user_id):
    assert put(auth_client, {**SNAPSHOT, "pastPlans": [PAST_PLAN]}).status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.activated_at is not None
    assert profile.snapshot.past_plans_count == 1


def test_past_plan_without_stops_does_not_activate(auth_client, user_id):
    data = {**SNAPSHOT, "pastPlans": [{**PAST_PLAN, "stopCount": 0}, {**PAST_PLAN, "id": "p2", "stopCount": -1}]}
    assert put(auth_client, data).status_code == 200
    profile = Profile.objects.get(id=user_id)
    assert profile.activated_at is None
    assert profile.snapshot.past_plans_count == 2  # the raw length, regardless of stops


@pytest.mark.parametrize(
    "bad", [{"id": "p1"}, {"id": "p1", "stopCount": "2"}, {"id": "p1", "stopCount": True}, "p1", 3]
)
def test_past_plan_with_a_bad_stop_count_does_not_activate(auth_client, user_id, bad):
    assert put(auth_client, {**SNAPSHOT, "pastPlans": [bad]}).status_code == 200
    assert Profile.objects.get(id=user_id).activated_at is None


def test_one_past_plan_with_stops_among_many_activates(auth_client, user_id):
    data = {**SNAPSHOT, "pastPlans": [{**PAST_PLAN, "stopCount": 0}, "junk", {**PAST_PLAN, "id": "p3", "stopCount": 1}]}
    assert put(auth_client, data).status_code == 200
    assert Profile.objects.get(id=user_id).activated_at is not None


def test_declared_oversize_body_is_413_before_parsing(auth_client):
    # CONTENT_LENGTH says 2 MB; the body is tiny. The view must refuse without reading `request.data`.
    response = auth_client.put(
        "/api/me/snapshot/", data=b'{"data": {}}', content_type="application/json", CONTENT_LENGTH="2000000"
    )
    assert response.status_code == 413
    assert "limit is 1000000" in response.json()["detail"]
    assert AppSnapshot.objects.count() == 0


def test_body_between_the_two_limits_gets_the_exact_check(auth_client):
    # 1.05 MB on the wire passes the 1.2 MB pre-check, parses, and fails the exact 1,000,000-byte check.
    response = put(auth_client, {"blob": "x" * 1_050_000})
    assert response.status_code == 413
    assert response.json()["detail"] == "Snapshot is 1050011 bytes; the limit is 1000000."
    assert AppSnapshot.objects.count() == 0


def test_snapshots_are_per_account(auth_client, other_client):
    assert put(auth_client, SNAPSHOT).status_code == 200
    assert other_client.get("/api/me/snapshot/").status_code == 404

    other_data = {**SNAPSHOT, "profile": {**SNAPSHOT["profile"], "name": "Other"}}
    assert put(other_client, other_data).json()["version"] == 1

    assert auth_client.get("/api/me/snapshot/").json()["data"] == SNAPSHOT
    assert other_client.get("/api/me/snapshot/").json()["data"] == other_data
    assert AppSnapshot.objects.count() == 2


def test_snapshot_requires_auth(api_client):
    assert api_client.get("/api/me/snapshot/").status_code == 401
    assert api_client.put("/api/me/snapshot/", {"data": {}}, format="json").status_code == 401
