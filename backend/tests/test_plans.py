from datetime import date, timedelta

import pytest
from django.utils import timezone

from plandit.plans.models import DayPlan, PlanStop, StopStatus, TravelLeg, TravelMode
from plandit.plans.services import estimate_leg, haversine_miles
from plandit.saved.models import ExtractionStatus, SavedPost, SourcePlatform

pytestmark = pytest.mark.django_db


def add_place(client, plan_id, place, **extra):
    return client.post(f"/api/plans/{plan_id}/stops/", {"place_id": str(place.id), **extra}, format="json")


def test_today_is_created_on_first_call(auth_client, profile):
    response = auth_client.get("/api/plans/today/")
    assert response.status_code == 200
    body = response.json()
    assert body["date"] == str(timezone.localdate())
    assert body["title"] == "Today"
    assert body["budget"] == 60
    assert body["stops"] == [] and body["legs"] == []
    assert auth_client.get("/api/plans/today/").json()["id"] == body["id"]
    assert DayPlan.objects.count() == 1


def test_adding_stops_estimates_legs(auth_client, profile, places):
    plan_id = auth_client.get("/api/plans/today/").json()["id"]

    first = add_place(auth_client, plan_id, places["pastry"], estimated_cost=9)
    assert first.status_code == 201
    assert len(first.json()["stops"]) == 1 and first.json()["legs"] == []

    second = add_place(auth_client, plan_id, places["bagels"], estimated_cost=5).json()
    assert [s["place"]["name"] for s in second["stops"]] == ["The Hungarian Pastry Shop", "Absolute Bagels"]
    assert len(second["legs"]) == 1
    walk = second["legs"][0]
    assert walk["mode"] == "walk"
    assert walk["from_stop"] == second["stops"][0]["id"] and walk["to_stop"] == second["stops"][1]["id"]
    assert walk["cost"] == 0
    assert second["total_cost"] == 14

    third = add_place(auth_client, plan_id, places["met"]).json()
    subway = third["legs"][1]
    assert subway["mode"] == "subway"
    assert subway["cost"] == 2.9
    assert third["total_cost"] == 16.9
    assert third["walking_miles"] == walk["miles"]

    stops = third["stops"]
    assert [s["position"] for s in stops] == [0, 1, 2]
    assert stops[1]["start"] > stops[0]["end"]


def test_adding_a_saved_post_uses_its_place_and_cost(auth_client, profile, places):
    post = SavedPost.objects.create(
        owner=profile,
        url="https://www.tiktok.com/@x/video/1",
        platform=SourcePlatform.TIKTOK,
        status=ExtractionStatus.READY,
        place=places["pastry"],
        estimated_cost=9,
    )
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    response = auth_client.post(f"/api/plans/{plan_id}/stops/", {"saved_post_id": str(post.id)}, format="json")
    assert response.status_code == 201
    stop = response.json()["stops"][0]
    assert stop["place"]["name"] == "The Hungarian Pastry Shop"
    assert stop["estimated_cost"] == 9
    assert stop["source_post"] == str(post.id)
    assert "TikTok" in stop["note"]

    again = auth_client.post(f"/api/plans/{plan_id}/stops/", {"saved_post_id": str(post.id)}, format="json")
    assert again.status_code == 400


def test_unmapped_saved_post_cannot_be_added(auth_client, profile):
    post = SavedPost.objects.create(
        owner=profile,
        url="https://www.tiktok.com/@x/video/2",
        platform=SourcePlatform.TIKTOK,
        status=ExtractionStatus.FAILED,
    )
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    response = auth_client.post(f"/api/plans/{plan_id}/stops/", {"saved_post_id": str(post.id)}, format="json")
    assert response.status_code == 400


def test_removing_a_middle_stop_rebuilds_legs(auth_client, profile, places):
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    add_place(auth_client, plan_id, places["pastry"])
    add_place(auth_client, plan_id, places["bagels"])
    body = add_place(auth_client, plan_id, places["met"]).json()
    middle = body["stops"][1]["id"]

    response = auth_client.delete(f"/api/plans/{plan_id}/stops/{middle}/")
    assert response.status_code == 200
    body = response.json()
    assert [s["place"]["name"] for s in body["stops"]] == ["The Hungarian Pastry Shop", "The Met"]
    assert [s["position"] for s in body["stops"]] == [0, 1]
    assert len(body["legs"]) == 1
    assert body["legs"][0]["from_stop"] == body["stops"][0]["id"]
    assert body["legs"][0]["to_stop"] == body["stops"][1]["id"]
    assert TravelLeg.objects.filter(plan_id=plan_id).count() == 1


def test_reordering_stops(auth_client, profile, places):
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    add_place(auth_client, plan_id, places["pastry"])
    add_place(auth_client, plan_id, places["bagels"])
    ids = [s["id"] for s in add_place(auth_client, plan_id, places["met"]).json()["stops"]]

    response = auth_client.post(f"/api/plans/{plan_id}/stops/reorder/", {"stop_ids": ids[::-1]}, format="json")
    assert response.status_code == 200
    assert [s["id"] for s in response.json()["stops"]] == ids[::-1]
    assert len(response.json()["legs"]) == 2

    bad = auth_client.post(f"/api/plans/{plan_id}/stops/reorder/", {"stop_ids": ids[:2]}, format="json")
    assert bad.status_code == 400


def test_stop_status_can_be_updated(auth_client, profile, places):
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    stop_id = add_place(auth_client, plan_id, places["pastry"]).json()["stops"][0]["id"]
    response = auth_client.patch(f"/api/plans/{plan_id}/stops/{stop_id}/", {"status": "done"}, format="json")
    assert response.status_code == 200
    assert response.json()["stops"][0]["status"] == "done"
    assert (
        auth_client.patch(f"/api/plans/{plan_id}/stops/{stop_id}/", {"status": "bogus"}, format="json").status_code
        == 400
    )


def test_plans_are_private_to_their_owner(auth_client, other_client, profile, places):
    plan_id = auth_client.get("/api/plans/today/").json()["id"]
    assert other_client.get(f"/api/plans/{plan_id}/").status_code == 404
    assert add_place(other_client, plan_id, places["pastry"]).status_code == 404
    assert other_client.get("/api/plans/").json() == []


def test_one_plan_per_day(auth_client, profile):
    auth_client.get("/api/plans/today/")
    response = auth_client.post("/api/plans/", {"title": "Another today"}, format="json")
    assert response.status_code == 400
    tomorrow = timezone.localdate() + timedelta(days=1)
    response = auth_client.post(
        "/api/plans/", {"title": "Tomorrow", "date": str(tomorrow), "budget": 40}, format="json"
    )
    assert response.status_code == 201
    assert response.json()["budget"] == 40
    listing = auth_client.get("/api/plans/").json()
    assert [p["title"] for p in listing] == ["Tomorrow", "Today"]
    assert listing[0]["stop_count"] == 0


def test_leg_estimate_matches_ios_heuristic(places):
    plan = DayPlan(date=date.today())
    a = PlanStop(plan=plan, place=places["pastry"], position=0, start=timezone.now())
    b = PlanStop(plan=plan, place=places["met"], position=1, start=timezone.now())
    leg = estimate_leg(plan, a, b)
    raw = haversine_miles(40.8036, -73.9636, 40.7794, -73.9632)
    assert leg.miles == round(raw * 1.25, 2)
    assert leg.mode == TravelMode.SUBWAY
    assert leg.minutes == 10 + round(leg.miles * 4)
    assert float(leg.cost) == 2.9


def test_stats_come_from_completed_past_plans(auth_client, profile, places):
    yesterday = timezone.localdate() - timedelta(days=1)
    plan = DayPlan.objects.create(owner=profile, date=yesterday, title="Yesterday", budget=30)
    now = timezone.now()
    first = PlanStop.objects.create(
        plan=plan, place=places["pastry"], position=0, start=now, estimated_cost=9, status=StopStatus.DONE
    )
    second = PlanStop.objects.create(
        plan=plan, place=places["bagels"], position=1, start=now, estimated_cost=5, status=StopStatus.DONE
    )
    TravelLeg.objects.create(plan=plan, from_stop=first, to_stop=second, mode=TravelMode.WALK, minutes=10, miles=0.5)
    auth_client.get("/api/plans/today/")  # today's empty plan must not count

    stats = auth_client.get("/api/me/stats/").json()
    assert stats == {
        "plans_completed": 1,
        "neighborhoods_visited": 1,
        "miles_walked": 0.5,
        "average_spend": 14.0,
        "plans_under_budget": 1,
        "streak_weeks": 1,
    }
