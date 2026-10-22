"""POST /api/plans/<id>/build/: the planner wired to the database and the existing plan endpoints."""

from datetime import datetime, timedelta
from decimal import Decimal

import pytest
from django.utils import timezone

from plandit.places.models import Place, PlaceCategory
from plandit.plans.models import DayPlan, PlanStop, StopStatus, TravelLeg
from plandit.saved.models import ExtractionStatus, SavedPost, SourcePlatform

pytestmark = pytest.mark.django_db


def at(hour, minute=0):
    return timezone.make_aware(datetime.combine(timezone.localdate(), datetime.min.time())) + timedelta(
        hours=hour, minutes=minute
    )


@pytest.fixture
def more_places(places):
    return {
        **places,
        "levain": Place.objects.create(
            name="Levain Bakery",
            category=PlaceCategory.FOOD,
            neighborhood="Upper West Side",
            address="167 W 74th St",
            latitude=40.7799,
            longitude=-73.9805,
            hours="Open until 8 PM",
        ),
        "tacos": Place.objects.create(
            name="Los Tacos No. 1",
            category=PlaceCategory.FOOD,
            neighborhood="Chelsea",
            address="75 Ninth Ave",
            latitude=40.7424,
            longitude=-74.0061,
            hours="Open until 9 PM",
        ),
        "cloisters": Place.objects.create(
            name="The Met Cloisters",
            category=PlaceCategory.CULTURE,
            neighborhood="Fort Tryon Park",
            address="99 Margaret Corbin Dr",
            latitude=40.8649,
            longitude=-73.9319,
            hours="Open until 5 PM",
        ),
    }


def save_post(profile, place, cost, n, status=ExtractionStatus.READY):
    return SavedPost.objects.create(
        owner=profile,
        url=f"https://www.tiktok.com/@x/video/{n}",
        platform=SourcePlatform.TIKTOK,
        status=status,
        place=place,
        estimated_cost=Decimal(cost) if cost is not None else None,
    )


@pytest.fixture
def posts(profile, more_places):
    return {
        "levain": save_post(profile, more_places["levain"], 6, 1),
        "tacos": save_post(profile, more_places["tacos"], 15, 2),
        "met": save_post(profile, more_places["met"], 5, 3),
        "smalls": save_post(profile, more_places["smalls"], 25, 4, ExtractionStatus.NEEDS_REVIEW),
        "cloisters": save_post(profile, more_places["cloisters"], 5, 5),
        "pending": save_post(profile, None, None, 6, ExtractionStatus.PROCESSING),
    }


def today_id(client):
    return client.get("/api/plans/today/").json()["id"]


def build(client, plan_id, **body):
    for key in ("start", "end"):
        if key in body:
            body[key] = body[key].isoformat()
    if "saved_post_ids" in body:
        body["saved_post_ids"] = [str(p.id) for p in body["saved_post_ids"]]
    return client.post(f"/api/plans/{plan_id}/build/", body, format="json")


def names(body):
    return [s["place"]["name"] for s in body["stops"]]


def test_start_over_plans_the_picked_posts(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    response = build(
        auth_client,
        plan_id,
        saved_post_ids=[posts["tacos"], posts["levain"], posts["met"]],
        start=at(10),
        budget="50",
        mode="replace",
    )
    assert response.status_code == 200, response.json()
    body = response.json()
    assert sorted(names(body)) == ["Levain Bakery", "Los Tacos No. 1", "The Met"]
    assert [s["position"] for s in body["stops"]] == [0, 1, 2]
    assert {s["source_post"] for s in body["stops"]} == {str(posts[k].id) for k in ("tacos", "levain", "met")}
    assert len(body["legs"]) == 2
    for leg, a, b in zip(body["legs"], body["stops"], body["stops"][1:], strict=False):
        assert (leg["from_stop"], leg["to_stop"]) == (a["id"], b["id"])
        assert b["start"] > a["end"]
    assert body["budget"] == 50
    assert body["total_cost"] <= 50
    assert body["skipped"] == []
    assert body["title"] != "Today"
    # No zig-zag: Levain sits between the Met and Chelsea, whichever direction the day runs.
    assert names(body)[1] == "Levain Bakery"


def test_skipped_posts_come_back_with_a_reason(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    body = build(
        auth_client,
        plan_id,
        saved_post_ids=[posts["levain"], posts["smalls"], posts["cloisters"]],
        start=at(17, 30),
        budget="20",
        mode="replace",
    ).json()
    reasons = {s["name"]: s["reason"] for s in body["skipped"]}
    assert reasons == {"The Met Cloisters": "closed", "Smalls Jazz Club": "over_budget"}
    assert names(body) == ["Levain Bakery"]
    skipped = next(s for s in body["skipped"] if s["name"] == "Smalls Jazz Club")
    assert skipped["saved_post_id"] == str(posts["smalls"].id) and skipped["stop_id"] is None


def test_add_keeps_done_stops_and_reorders_the_rest(auth_client, profile, places, posts):
    plan_id = today_id(auth_client)
    plan = DayPlan.objects.get(pk=plan_id)
    # A day in progress built with the existing endpoints: pastry done, Met now, Smalls later.
    for place in (places["pastry"], places["met"], places["smalls"]):
        auth_client.post(
            f"/api/plans/{plan_id}/stops/", {"place_id": str(place.id), "start": at(9).isoformat()}, format="json"
        )
    stops = list(plan.stops.order_by("position"))
    PlanStop.objects.filter(pk=stops[0].pk).update(status=StopStatus.DONE, start=at(9))
    PlanStop.objects.filter(pk=stops[1].pk).update(status=StopStatus.NOW, start=at(10))
    locked_leg = TravelLeg.objects.get(from_stop=stops[0], to_stop=stops[1])
    TravelLeg.objects.filter(pk=locked_leg.pk).update(detail="M4 bus")

    body = build(auth_client, plan_id, saved_post_ids=[posts["levain"], posts["tacos"]], budget="80", mode="add").json()

    assert [s["id"] for s in body["stops"][:2]] == [str(stops[0].id), str(stops[1].id)]
    assert [s["status"] for s in body["stops"]] == ["done", "now", "upcoming", "upcoming", "upcoming"]
    assert str(stops[2].id) in [s["id"] for s in body["stops"]], "the upcoming stop keeps its id"
    assert names(body)[2] == "Levain Bakery", "a short walk from the Met"
    assert body["stops"][2]["start"] >= body["stops"][1]["end"]
    assert [s["position"] for s in body["stops"]] == [0, 1, 2, 3, 4]
    assert len(body["legs"]) == 4
    assert body["legs"][0]["detail"] == "M4 bus", "legs between finished stops are left alone"
    for leg, a, b in zip(body["legs"], body["stops"], body["stops"][1:], strict=False):
        assert (leg["from_stop"], leg["to_stop"]) == (a["id"], b["id"])
    assert TravelLeg.objects.filter(plan_id=plan_id).count() == 4


def test_add_does_not_duplicate_a_post_already_in_the_plan(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    build(auth_client, plan_id, saved_post_ids=[posts["levain"]], start=at(10), mode="replace")
    body = build(auth_client, plan_id, saved_post_ids=[posts["levain"], posts["met"]], start=at(10), mode="add").json()
    assert sorted(names(body)) == ["Levain Bakery", "The Met"]


def test_free_until_keeps_the_day_inside_the_window(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    body = build(
        auth_client,
        plan_id,
        saved_post_ids=[posts["levain"], posts["met"], posts["tacos"], posts["smalls"]],
        start=at(13),
        end=at(16),
        budget="100",
        mode="replace",
    ).json()
    assert datetime.fromisoformat(body["stops"][-1]["end"]) <= at(16)
    reasons = {s["name"]: s["reason"] for s in body["skipped"]}
    assert reasons["Smalls Jazz Club"] == "evening_only"
    assert set(reasons.values()) <= {"evening_only", "out_of_time"}


def test_free_until_after_midnight_rolls_over(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    body = build(
        auth_client, plan_id, saved_post_ids=[posts["smalls"]], start=at(22), end=at(1), budget="100", mode="replace"
    ).json()
    assert names(body) == ["Smalls Jazz Club"] and body["skipped"] == []


def test_dry_run_changes_nothing(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    body = build(
        auth_client, plan_id, saved_post_ids=[posts["levain"], posts["met"]], start=at(10), dry_run=True
    ).json()
    assert len(body["stops"]) == 2
    saved = auth_client.get(f"/api/plans/{plan_id}/").json()
    assert saved["stops"] == [] and saved["legs"] == [] and saved["title"] == "Today"
    assert PlanStop.objects.count() == 0


def test_walk_only_profile_only_walks(auth_client, profile, posts):
    profile.travel_modes = "Walk only"
    profile.save()
    plan_id = today_id(auth_client)
    body = build(
        auth_client, plan_id, saved_post_ids=[posts["cloisters"], posts["tacos"]], start=at(10), mode="replace"
    ).json()
    assert [leg["mode"] for leg in body["legs"]] == ["walk"]


def test_budget_defaults_to_the_plans_budget(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    auth_client.patch(f"/api/plans/{plan_id}/", {"budget": "10"}, format="json")
    body = build(auth_client, plan_id, saved_post_ids=[posts["tacos"], posts["levain"]], start=at(10)).json()
    assert names(body) == ["Levain Bakery"]
    assert body["budget"] == 10


def test_future_plan_starts_at_ten(auth_client, profile, posts):
    tomorrow = timezone.localdate() + timedelta(days=1)
    plan_id = auth_client.post("/api/plans/", {"date": str(tomorrow)}, format="json").json()["id"]
    body = build(auth_client, plan_id, saved_post_ids=[posts["levain"]], mode="replace").json()
    start = datetime.fromisoformat(body["stops"][0]["start"])
    assert timezone.localtime(start).date() == tomorrow
    assert (timezone.localtime(start).hour, timezone.localtime(start).minute) == (10, 0)


@pytest.mark.parametrize("which", ["pending", "unknown", "other_users"])
def test_bad_post_ids_are_rejected(auth_client, other_client, profile, posts, which):
    plan_id = today_id(auth_client)
    if which == "pending":
        ids = [str(posts["pending"].id)]
    elif which == "unknown":
        ids = ["00000000-0000-0000-0000-000000000000"]
    else:
        other_client.get("/api/plans/today/")  # creates the other user's profile
        from plandit.core.models import Profile

        other = Profile.objects.exclude(pk=profile.pk).get()
        ids = [str(save_post(other, posts["levain"].place, 6, 99).id)]
    response = auth_client.post(f"/api/plans/{plan_id}/build/", {"saved_post_ids": ids}, format="json")
    assert response.status_code == 400
    assert "saved_post_ids" in response.json()
    assert PlanStop.objects.count() == 0


def test_cannot_build_someone_elses_plan(auth_client, other_client, profile, posts):
    plan_id = today_id(auth_client)
    response = other_client.post(f"/api/plans/{plan_id}/build/", {"saved_post_ids": []}, format="json")
    assert response.status_code == 404


def test_built_plan_works_with_the_existing_endpoints(auth_client, profile, posts):
    plan_id = today_id(auth_client)
    body = build(
        auth_client,
        plan_id,
        saved_post_ids=[posts["levain"], posts["met"], posts["tacos"]],
        start=at(10),
        mode="replace",
    ).json()
    ids = [s["id"] for s in body["stops"]]

    reordered = auth_client.post(f"/api/plans/{plan_id}/stops/reorder/", {"stop_ids": ids[::-1]}, format="json")
    assert reordered.status_code == 200
    assert [s["id"] for s in reordered.json()["stops"]] == ids[::-1]
    assert len(reordered.json()["legs"]) == 2

    removed = auth_client.delete(f"/api/plans/{plan_id}/stops/{ids[1]}/")
    assert removed.status_code == 200
    assert len(removed.json()["stops"]) == 2 and len(removed.json()["legs"]) == 1

    marked = auth_client.patch(f"/api/plans/{plan_id}/stops/{ids[0]}/", {"status": "done"}, format="json")
    assert marked.status_code == 200
    assert auth_client.get("/api/plans/").json()[0]["stop_count"] == 2
