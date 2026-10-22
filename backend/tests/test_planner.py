"""The planner on its own (no database). Mirrors ios/PlanditTests/DayPlannerTests.swift."""

import random
import time as clock
from datetime import datetime, timedelta
from decimal import Decimal
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

from plandit.plans import planner
from plandit.plans.planner import Anchor, Candidate, SkipReason, closing_time, plan_day

NY = ZoneInfo("America/New_York")


def at(hour, minute=0, day_offset=0):
    return datetime(2026, 10, 22, tzinfo=NY) + timedelta(days=day_offset, hours=hour, minutes=minute)


def place(name, lat, lon, hours=None, category="activity", neighborhood="Test"):
    return SimpleNamespace(
        name=name, address=f"{name} St", latitude=lat, longitude=lon, hours=hours, category=category, id=name
    )


PASTRY = place("The Hungarian Pastry Shop", 40.8036, -73.9636, "Open until 9 PM", "coffee")
MET = place("The Met", 40.7794, -73.9632, "Open until 5 PM", "culture")
HIGH_LINE = place("The High Line", 40.7527, -74.0016, "Open until 10 PM", "outdoors")
TACOS = place("Los Tacos No. 1", 40.7424, -74.0061, "Open until 9 PM", "food")
WASHINGTON_SQUARE = place("Washington Square Park", 40.7308, -73.9973, "Open until midnight", "outdoors")
JOES = place("Joe's Pizza", 40.7305, -74.0021, "Open late", "food")
LEVAIN = place("Levain Bakery", 40.7799, -73.9805, "Open until 8 PM", "food")
LITTLE_ISLAND = place("Little Island", 40.7420, -74.0103, "Open until 9 PM", "outdoors")
CLOISTERS = place("The Met Cloisters", 40.8649, -73.9319, "Open until 5 PM", "culture")
SMALLS = place("Smalls Jazz Club", 40.7344, -74.0027, None, "nightlife")
RUSS = place("Russ & Daughters", 40.7226, -73.9883, "Open until 6 PM", "food")
TRAM = place("Roosevelt Island Tram", 40.7612, -73.9643, "Runs until 2 AM", "activity")
SAMPLE = [PASTRY, MET, HIGH_LINE, TACOS, WASHINGTON_SQUARE, JOES, LEVAIN, LITTLE_ISLAND, CLOISTERS, SMALLS, RUSS, TRAM]


def pick(p, cost=0, minutes=None):
    return Candidate(place=p, cost=Decimal(cost), duration_minutes=minutes, key=p.name)


def names(outcome):
    return [s.candidate.place.name for s in outcome.stops]


def without_hours(p):
    return SimpleNamespace(**{**vars(p), "hours": None})


# MARK: - Basics


def test_no_candidates_plans_nothing():
    outcome = plan_day([], start=at(10), budget=Decimal(60))
    assert outcome.stops == [] and outcome.legs == [] and outcome.skipped == []


def test_one_candidate_starts_at_the_start_time():
    outcome = plan_day([pick(LEVAIN, 6)], start=at(10), budget=Decimal(60))
    assert len(outcome.stops) == 1
    assert outcome.stops[0].start == at(10)
    assert outcome.stops[0].duration_minutes == planner.TYPICAL_VISIT_MINUTES["food"]
    assert outcome.legs == []
    assert outcome.cost == 6


def test_start_rounds_up_to_five_minutes():
    assert plan_day([pick(LEVAIN)], start=at(10, 7), budget=Decimal(60)).stops[0].start == at(10, 10)


def test_start_must_be_timezone_aware():
    with pytest.raises(ValueError):
        plan_day([pick(LEVAIN)], start=datetime(2026, 10, 22, 10), budget=Decimal(60))


def test_same_place_twice_is_one_stop():
    outcome = plan_day([pick(LEVAIN), pick(LEVAIN), pick(MET)], start=at(10), budget=Decimal(60))
    assert sorted(names(outcome)) == ["Levain Bakery", "The Met"]


# MARK: - Ordering


def test_places_along_a_line_are_visited_in_line_order():
    north, middle, south = place("North", 40.80, -73.96), place("Middle", 40.78, -73.97), place("South", 40.76, -73.98)
    order = names(plan_day([pick(middle), pick(south), pick(north)], start=at(10), budget=Decimal(60)))
    assert order in (["North", "Middle", "South"], ["South", "Middle", "North"])


def test_order_beats_the_picked_order():
    picks = [pick(CLOISTERS), pick(JOES), pick(PASTRY), pick(TACOS)]
    as_picked = sum(planner.estimate_travel(a.place, b.place).minutes for a, b in zip(picks, picks[1:], strict=False))
    outcome = plan_day(picks, start=at(9), budget=Decimal(100))
    assert len(outcome.stops) == 4
    assert outcome.travel_minutes < as_picked


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_fast_search_matches_exact_search(seed):
    daytime = [without_hours(p) for p in SAMPLE if p.category != "nightlife"]  # only travel matters
    places = random.Random(seed).sample(daytime, 7)
    picks = [pick(p) for p in places]
    exact = plan_day(picks, start=at(9), budget=Decimal(500), exact_search_limit=7)
    fast = plan_day(picks, start=at(9), budget=Decimal(500), exact_search_limit=0)
    assert exact.travel_minutes <= fast.travel_minutes
    assert fast.travel_minutes <= exact.travel_minutes * 1.05


def test_planning_is_deterministic():
    picks = [pick(p, 3) for p in SAMPLE]
    first, second = plan_day(picks, start=at(9), budget=Decimal(60)), plan_day(picks, start=at(9), budget=Decimal(60))
    assert names(first) == names(second)
    assert [s.start for s in first.stops] == [s.start for s in second.stops]


def test_a_typical_pick_plans_quickly():
    started = clock.perf_counter()
    plan_day([pick(p, 2) for p in SAMPLE[:7]], start=at(9), budget=Decimal(100))
    assert clock.perf_counter() - started < 2.0


# MARK: - Schedule and hours


def test_stops_follow_each_other_with_travel_between():
    outcome = plan_day([pick(p, 5) for p in (LEVAIN, MET, HIGH_LINE, TACOS)], start=at(10), budget=Decimal(60))
    assert len(outcome.legs) == len(outcome.stops) - 1
    for a, b, leg in zip(outcome.stops, outcome.stops[1:], outcome.legs, strict=False):
        assert b.start >= a.end + timedelta(minutes=leg.minutes)
        assert b.start < a.end + timedelta(minutes=leg.minutes + 5)


def test_place_that_closes_soon_goes_first():
    outcome = plan_day([pick(HIGH_LINE), pick(MET)], start=at(15, 30), budget=Decimal(60))
    assert names(outcome)[0] == "The Met"
    assert outcome.stops[0].end <= at(17)
    assert "closes at 5 PM" in outcome.stops[0].note


def test_visit_is_shortened_to_end_at_closing():
    stop = plan_day([pick(MET)], start=at(16), budget=Decimal(60)).stops[0]
    assert stop.duration_minutes == 60 and stop.end == at(17)


def test_closed_place_is_left_out_with_a_reason():
    outcome = plan_day([pick(MET), pick(HIGH_LINE)], start=at(17, 30), budget=Decimal(60))
    assert names(outcome) == ["The High Line"]
    assert [(s.candidate.place.name, s.reason) for s in outcome.skipped] == [("The Met", SkipReason.CLOSED)]


@pytest.mark.parametrize(
    ("hours", "expected"),
    [
        ("Open until 9 PM", at(21)),
        ("Open until 5:30 pm", at(17, 30)),
        ("Open until 11 AM", at(11)),
        ("Open until noon", at(12)),
        ("Open until midnight", at(0, day_offset=1)),
        ("Runs until 2 AM", at(2, day_offset=1)),
        ("Open until 12 AM", at(0, day_offset=1)),
        ("Open late", None),
        ("Shows at 7:30 PM", None),
        ("Open until 25 PM", None),
        (None, None),
        ("", None),
    ],
)
def test_closing_times_are_read_from_hours(hours, expected):
    assert closing_time(hours, at(12).date(), NY) == expected


# MARK: - Evening places


def test_nightlife_waits_for_the_evening():
    outcome = plan_day([pick(SMALLS), pick(JOES), pick(WASHINGTON_SQUARE)], start=at(15), budget=Decimal(100))
    assert names(outcome)[-1] == "Smalls Jazz Club"
    assert outcome.stops[-1].start >= at(20)
    assert "evening spot" in outcome.stops[-1].note
    assert outcome.skipped == []


def test_daytime_stops_still_minimize_travel_before_an_evening_stop():
    outcome = plan_day([pick(TACOS), pick(SMALLS), pick(LEVAIN), pick(MET)], start=at(10), budget=Decimal(100))
    assert set(names(outcome)[:2]) == {"The Met", "Levain Bakery"}
    assert names(outcome)[2:] == ["Los Tacos No. 1", "Smalls Jazz Club"]


def test_nightlife_alone_starts_at_eight():
    assert plan_day([pick(SMALLS)], start=at(13), budget=Decimal(100)).stops[0].start == at(20)
    assert plan_day([pick(SMALLS)], start=at(21, 30), budget=Decimal(100)).stops[0].start == at(21, 30)


def test_nightlife_is_left_out_when_the_day_ends_before_evening():
    outcome = plan_day([pick(SMALLS), pick(LEVAIN)], start=at(13), budget=Decimal(100), day_end=at(18))
    assert names(outcome) == ["Levain Bakery"]
    assert [s.reason for s in outcome.skipped] == [SkipReason.EVENING_ONLY]


def test_waiting_for_evening_does_not_push_daytime_places_past_closing():
    outcome = plan_day([pick(SMALLS), pick(MET)], start=at(15), budget=Decimal(100))
    assert names(outcome) == ["The Met", "Smalls Jazz Club"]


# MARK: - Budget and travel


def test_over_budget_drops_the_most_expensive_stop():
    picks = [pick(JOES, 7), pick(TACOS, 15), pick(WASHINGTON_SQUARE, 0), pick(LITTLE_ISLAND, 0)]
    outcome = plan_day(picks, start=at(12), budget=Decimal(10), walk_only=True)
    assert [(s.candidate.place.name, s.reason) for s in outcome.skipped] == [
        ("Los Tacos No. 1", SkipReason.OVER_BUDGET)
    ]
    assert outcome.cost <= 10 and len(outcome.stops) == 3


def test_subway_fares_count_against_the_budget():
    picks = [pick(CLOISTERS), pick(WASHINGTON_SQUARE)]
    transit = plan_day(picks, start=at(10), budget=Decimal(0))
    assert len(transit.stops) == 1 and [s.reason for s in transit.skipped] == [SkipReason.OVER_BUDGET]
    walking = plan_day(picks, start=at(10), budget=Decimal(0), walk_only=True)
    assert len(walking.stops) == 2 and [leg.mode for leg in walking.legs] == ["walk"] and walking.cost == 0


def test_money_already_spent_counts():
    outcome = plan_day([pick(LEVAIN, 6)], start=at(10), budget=Decimal(20), already_spent=Decimal(18))
    assert outcome.stops == [] and [s.reason for s in outcome.skipped] == [SkipReason.OVER_BUDGET]


def test_walk_only_setting():
    assert planner.walk_only("Walk only")
    assert not planner.walk_only("Walk + subway")
    assert not planner.walk_only("Walk + subway + bus")
    outcome = plan_day([pick(p) for p in SAMPLE[:6]], start=at(9), budget=Decimal(100), walk_only=True)
    assert outcome.legs and all(leg.mode == "walk" and leg.cost == 0 for leg in outcome.legs)


# MARK: - End of day and anchors


def test_day_that_runs_too_late_leaves_stops_out():
    picks = [pick(without_hours(p), minutes=120) for p in (LEVAIN, MET, HIGH_LINE, JOES)]
    outcome = plan_day(picks, start=at(22), budget=Decimal(100))
    assert outcome.skipped and all(s.reason == SkipReason.OUT_OF_TIME for s in outcome.skipped)
    assert outcome.stops[-1].end <= at(2, day_offset=1)
    assert len(outcome.stops) + len(outcome.skipped) == 4


def test_new_stops_follow_the_anchor():
    anchor = Anchor(MET, at(13))
    outcome = plan_day([pick(LEVAIN), pick(HIGH_LINE)], start=at(9), budget=Decimal(60), anchor=anchor)
    assert outcome.leg_from_anchor and len(outcome.legs) == len(outcome.stops)
    assert outcome.stops[0].start >= at(13)
    assert names(outcome)[0] == "Levain Bakery"


# MARK: - Invariants over many random days


def test_random_days_keep_the_planners_promises():
    rng = random.Random(2026)
    for round_ in range(150):
        chosen = rng.sample(SAMPLE, rng.randint(0, 6))
        picks = [pick(p, rng.randint(0, 20), rng.choice([None, 30, 60, 90])) for p in chosen]
        start = at(rng.randint(7, 21), rng.choice([0, 5, 20, 45]))
        budget = Decimal(rng.randint(0, 80))
        walk = rng.random() < 0.5
        outcome = plan_day(picks, start=start, budget=budget, walk_only=walk)
        label = f"round {round_}"

        assert {s.candidate.key for s in outcome.stops} | {s.candidate.key for s in outcome.skipped} == {
            c.key for c in picks
        }, label
        assert len(outcome.stops) + len(outcome.skipped) == len(picks), label
        assert outcome.cost <= budget, label
        if outcome.stops:
            assert outcome.stops[0].start >= start, label
            assert outcome.stops[-1].end <= at(2, day_offset=1), label
        for a, b in zip(outcome.stops, outcome.stops[1:], strict=False):
            assert b.start >= a.end, label
        for stop in outcome.stops:
            if stop.candidate.place.category == "nightlife":
                assert stop.start >= at(20), f"{label}: {stop.candidate.place.name}"
            close = closing_time(stop.candidate.place.hours, start.date(), NY)
            if close:
                assert stop.end <= close, f"{label}: {stop.candidate.place.name}"
        assert len(outcome.legs) == max(0, len(outcome.stops) - 1), label
        if walk:
            assert all(leg.mode == "walk" for leg in outcome.legs), label
