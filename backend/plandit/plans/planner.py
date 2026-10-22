"""
The day planner: turns picked places into an ordered, timed day. Same rules as the iOS DayPlanner
(ios/Plandit/Services/DayPlanner.swift), so the app and the API agree on what a plan looks like.

- Order: the least total travel. Up to EXACT_SEARCH_LIMIT stops every order is tried; above it,
  nearest-neighbor tours polished with 2-opt and single-stop moves.
- Hours: a visit has to fit before the place closes (read from hours like "Open until 9 PM"); it's
  shortened to end at closing if needed, as long as MINIMUM_STAY_MINUTES still fit.
- Evening places: nightlife doesn't start before 8 PM; it's left out if the day ends before then.
- Budget: stop costs plus fares, plus anything already spent today, stay under the budget.
- Anything that can't fit is returned in `skipped` with a reason, never silently dropped.

Pure Python with no database access, so it's cheap to test and to call for previews.
"""

import itertools
import math
import re
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from decimal import Decimal
from typing import Any

STREET_GRID_DETOUR = 1.25
WALK_LIMIT_MILES = 1.2
WALK_MINUTES_PER_MILE = 20
SUBWAY_FARE = Decimal("2.90")
MINIMUM_STAY_MINUTES = 30
EXACT_SEARCH_LIMIT = 7
LATE_PENALTY = 10_000  # one minute late at a closing place outweighs any amount of travel

TYPICAL_VISIT_MINUTES = {
    "food": 45,
    "coffee": 45,
    "activity": 60,
    "outdoors": 75,
    "culture": 120,
    "nightlife": 90,
    "shopping": 45,
}


class SkipReason:
    CLOSED = "closed"
    OVER_BUDGET = "over_budget"
    OUT_OF_TIME = "out_of_time"
    EVENING_ONLY = "evening_only"  # a nightlife spot when the day ends before evening


# Places that only make sense in the evening don't start before this time (minutes after midnight).
EARLIEST_START_MINUTES = {"nightlife": 20 * 60}


def opening(candidate, day, tzinfo) -> datetime | None:
    """The earliest a place should start, for evening-only places; None when any time works."""
    minutes = EARLIEST_START_MINUTES.get(candidate.place.category)
    return None if minutes is None else datetime.combine(day, time(0), tzinfo) + timedelta(minutes=minutes)


def walk_only(travel_modes: str) -> bool:
    """Profile setting ("Walk only", "Walk + subway", ...) -> whether transit is off."""
    setting = (travel_modes or "").lower()
    return "subway" not in setting and "bus" not in setting


# MARK: - Travel


def haversine_miles(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius_miles = 3958.8
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * radius_miles * math.asin(math.sqrt(a))


@dataclass(frozen=True)
class Travel:
    mode: str  # "walk" or "subway" (TravelMode values)
    minutes: int
    miles: float
    cost: Decimal = Decimal(0)
    detail: str = ""


def estimate_travel(a, b, *, walk_only: bool = False) -> Travel:
    """Rough leg between two places: walk under ~1.2 mi (or always, for walk-only), otherwise subway."""
    miles = round(haversine_miles(a.latitude, a.longitude, b.latitude, b.longitude) * STREET_GRID_DETOUR, 2)
    if miles <= WALK_LIMIT_MILES or walk_only:
        return Travel("walk", max(3, round(miles * WALK_MINUTES_PER_MILE)), miles)
    return Travel("subway", 10 + round(miles * 4), miles, SUBWAY_FARE, "Subway")


# MARK: - Hours

_CLOCK = re.compile(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)")


def closing_time(hours: str | None, day: date, tzinfo) -> datetime | None:
    """When a place closes on `day`, from hours like "Open until 9 PM", "Runs until 2 AM" or
    "Open until midnight". None when the hours don't say ("Open late", "Shows at 7:30 PM", blank)."""
    if not hours:
        return None
    text = hours.lower()
    marker = text.find("until ")
    if marker < 0:
        return None
    rest = text[marker + len("until ") :].strip()
    minute = 0
    if rest.startswith("midnight"):
        hour = 24
    elif rest.startswith("noon"):
        hour = 12
    else:
        match = _CLOCK.match(rest)
        if not match or not 1 <= int(match.group(1)) <= 12:
            return None
        hour = int(match.group(1)) % 12 + (12 if match.group(3).startswith("p") else 0)
        minute = int(match.group(2) or 0)
        if hour < 6:  # "until 2 AM" means the early hours of the next day
            hour += 24
    return datetime.combine(day, time(0), tzinfo) + timedelta(hours=hour, minutes=minute)


# MARK: - Planning


@dataclass
class Candidate:
    """A place the user wants in the day. `key` is whatever the caller needs back (a stop, a post)."""

    place: Any  # anything with name, address, latitude, longitude, hours, category
    cost: Decimal = Decimal(0)
    duration_minutes: int | None = None
    key: Any = None
    note: str = ""

    def __post_init__(self):
        self.cost = max(Decimal(0), Decimal(self.cost))
        if self.duration_minutes is None:
            self.duration_minutes = TYPICAL_VISIT_MINUTES.get(self.place.category, 60)
        self.duration_minutes = max(5, self.duration_minutes)


@dataclass
class Anchor:
    """The stop the user is at or just finished; new stops follow it."""

    place: Any
    end: datetime


@dataclass
class PlannedStop:
    candidate: Candidate
    start: datetime
    duration_minutes: int
    note: str

    @property
    def end(self) -> datetime:
        return self.start + timedelta(minutes=self.duration_minutes)


@dataclass
class Skipped:
    candidate: Candidate
    reason: str


@dataclass
class Outcome:
    stops: list[PlannedStop] = field(default_factory=list)
    # legs[i] is the travel into stops[i] when there's an anchor, else into stops[i + 1].
    legs: list[Travel] = field(default_factory=list)
    skipped: list[Skipped] = field(default_factory=list)
    leg_from_anchor: bool = False

    @property
    def cost(self) -> Decimal:
        return sum((s.candidate.cost for s in self.stops), Decimal(0)) + sum(
            (leg.cost for leg in self.legs), Decimal(0)
        )

    @property
    def travel_minutes(self) -> int:
        return sum(leg.minutes for leg in self.legs)


def plan_day(
    candidates: list[Candidate],
    *,
    start: datetime,
    budget: Decimal,
    walk_only: bool = False,
    anchor: Anchor | None = None,
    already_spent: Decimal = Decimal(0),
    day_end: datetime | None = None,
    exact_search_limit: int = EXACT_SEARCH_LIMIT,
) -> Outcome:
    if start.tzinfo is None:
        raise ValueError("start must be timezone-aware")
    if day_end is None:
        day_end = datetime.combine(start.date(), time(0), start.tzinfo) + timedelta(hours=26)
    budget = Decimal(budget)

    kept: list[Candidate] = []
    skipped: list[Skipped] = []
    for candidate in _deduplicated(candidates):
        opens = opening(candidate, start.date(), start.tzinfo)
        if opens and opens + timedelta(minutes=min(MINIMUM_STAY_MINUTES, candidate.duration_minutes)) > day_end:
            skipped.append(Skipped(candidate, SkipReason.EVENING_ONLY))
        else:
            kept.append(candidate)
    while kept:
        problem = _Problem(kept, start=start, anchor=anchor, walk_only=walk_only, exact_search_limit=exact_search_limit)
        order = problem.best_order()
        schedule = problem.schedule(order)

        late = [p for p in range(len(order)) if schedule.lateness[p] > 0]
        if late:
            worst = max(late, key=lambda p: (schedule.lateness[p], order[p]))
            skipped.append(Skipped(kept.pop(order[worst]), SkipReason.CLOSED))
            continue
        if schedule.end > day_end:
            position = problem.position_saving_most(
                order, lambda c: Decimal(c.duration_minutes), lambda t: Decimal(t.minutes)
            )
            skipped.append(Skipped(kept.pop(order[position]), SkipReason.OUT_OF_TIME))
            continue
        if already_spent + schedule.cost > budget:
            position = problem.position_saving_most(order, lambda c: c.cost, lambda t: t.cost)
            skipped.append(Skipped(kept.pop(order[position]), SkipReason.OVER_BUDGET))
            continue
        return problem.outcome(order, schedule, skipped)
    return Outcome(skipped=skipped, leg_from_anchor=anchor is not None)


def _deduplicated(candidates: list[Candidate]) -> list[Candidate]:
    seen, kept = set(), []
    for candidate in candidates:
        key = (candidate.place.name.lower(), (candidate.place.address or "").lower())
        if key not in seen:
            seen.add(key)
            kept.append(candidate)
    return kept


def _round_up_to_five_minutes(moment: datetime) -> datetime:
    step = 300
    timestamp = moment.timestamp()
    return datetime.fromtimestamp(math.ceil(timestamp / step) * step, moment.tzinfo)


@dataclass
class _Schedule:
    starts: list[datetime]
    durations: list[int]
    lateness: list[int]
    travel_minutes: int
    wait_minutes: int  # waiting for an evening place to get going
    cost: Decimal
    end: datetime

    @property
    def score(self) -> int:
        # Travel counts double: before a fixed evening start, travel + waiting adds up to the same total in
        # every order, so weighing them equally would stop the planner caring about travel at all.
        return sum(self.lateness) * LATE_PENALTY + self.travel_minutes * 2 + self.wait_minutes


class _Problem:
    def __init__(self, candidates, *, start, anchor, walk_only, exact_search_limit):
        self.candidates = candidates
        self.start = start
        self.anchor = anchor
        self.exact_search_limit = exact_search_limit
        self.legs = [[estimate_travel(a.place, b.place, walk_only=walk_only) for b in candidates] for a in candidates]
        self.from_anchor = (
            [estimate_travel(anchor.place, c.place, walk_only=walk_only) for c in candidates] if anchor else None
        )
        self.closes = [closing_time(c.place.hours, start.date(), start.tzinfo) for c in candidates]
        self.opens = [opening(c, start.date(), start.tzinfo) for c in candidates]

    def leg_into(self, position: int, order: list[int]) -> Travel | None:
        if position == 0:
            return self.from_anchor[order[0]] if self.from_anchor else None
        return self.legs[order[position - 1]][order[position]]

    def schedule(self, order: list[int]) -> _Schedule:
        clock = self.anchor.end if self.anchor else self.start
        starts, durations, lateness = [], [], []
        travel_minutes, wait_minutes, cost = 0, 0, Decimal(0)
        for position, index in enumerate(order):
            candidate = self.candidates[index]
            leg = self.leg_into(position, order)
            if leg:
                clock += timedelta(minutes=leg.minutes)
                travel_minutes += leg.minutes
                cost += leg.cost
            arrival = _round_up_to_five_minutes(clock)
            opens = self.opens[index]
            if opens and arrival < opens:
                wait_minutes += int((opens - arrival).total_seconds() // 60)
                arrival = opens
            duration, late = candidate.duration_minutes, 0
            close = self.closes[index]
            if close is not None:
                available = int((close - arrival).total_seconds() // 60)
                needed = min(MINIMUM_STAY_MINUTES, duration)
                if available < needed:
                    late = needed - available
                else:
                    duration = min(duration, available)
            starts.append(arrival)
            durations.append(duration)
            lateness.append(late)
            cost += candidate.cost
            clock = arrival + timedelta(minutes=duration)
        return _Schedule(starts, durations, lateness, travel_minutes, wait_minutes, cost, clock)

    def best_order(self) -> list[int]:
        n = len(self.candidates)
        if n <= 1:
            return list(range(n))
        if n <= self.exact_search_limit:
            # Permutations come in lexicographic order and only a strictly better score replaces the
            # best, so ties keep the order the user picked things in.
            return list(min(itertools.permutations(range(n)), key=lambda order: self.schedule(list(order)).score))
        return self._heuristic_order()

    def _heuristic_order(self) -> list[int]:
        n = len(self.candidates)
        seeds = [list(range(n))]
        for first in range(n):
            tour, remaining = [first], set(range(n)) - {first}
            while remaining:
                current = tour[-1]
                nearest = min(remaining, key=lambda j: (self.legs[current][j].minutes, j))
                tour.append(nearest)
                remaining.remove(nearest)
            seeds.append(tour)

        best, best_score = seeds[0], self.schedule(seeds[0]).score
        for seed in seeds:
            tour, score = self._improve(seed)
            if score < best_score:
                best, best_score = tour, score
        return best

    def _improve(self, tour: list[int]) -> tuple[list[int], int]:
        score = self.schedule(tour).score
        improved = True
        while improved:
            improved = False
            for i in range(len(tour) - 1):  # 2-opt: reverse a stretch of the route
                for j in range(i + 1, len(tour)):
                    candidate = tour[:i] + tour[i : j + 1][::-1] + tour[j + 1 :]
                    candidate_score = self.schedule(candidate).score
                    if candidate_score < score:
                        tour, score, improved = candidate, candidate_score, True
            for i in range(len(tour)):  # move one stop somewhere else in the day
                for j in range(len(tour)):
                    if i == j:
                        continue
                    candidate = tour[:]
                    candidate.insert(j, candidate.pop(i))
                    candidate_score = self.schedule(candidate).score
                    if candidate_score < score:
                        tour, score, improved = candidate, candidate_score, True
        return tour, score

    def position_saving_most(self, order, stop_value, leg_value) -> int:
        """The position whose removal saves the most; ties drop the stop picked last."""

        def saving(position: int) -> Decimal:
            saved = stop_value(self.candidates[order[position]])
            into = self.leg_into(position, order)
            if into:
                saved += leg_value(into)
            if position + 1 < len(order):
                saved += leg_value(self.legs[order[position]][order[position + 1]])
                if position > 0:
                    saved -= leg_value(self.legs[order[position - 1]][order[position + 1]])
                elif self.from_anchor:
                    saved -= leg_value(self.from_anchor[order[position + 1]])
            return saved

        return max(range(len(order)), key=lambda p: (saving(p), order[p]))

    def outcome(self, order, schedule: _Schedule, skipped) -> Outcome:
        stops = []
        for position, index in enumerate(order):
            candidate = self.candidates[index]
            note = candidate.note
            close = self.closes[index]
            starts_at = schedule.starts[position]
            if close is not None and close - starts_at <= timedelta(minutes=schedule.durations[position] + 60):
                closes_at = close.strftime("%-I:%M %p").replace(":00 ", " ")
                note = " ".join(part for part in (note, f"Goes here before it closes at {closes_at}.") if part)
            if self.opens[index]:
                opens_at = self.opens[index].strftime("%-I:%M %p").replace(":00 ", " ")
                note = " ".join(
                    part for part in (note, f"It's an evening spot, so it starts after {opens_at}.") if part
                )
            stops.append(PlannedStop(candidate, starts_at, schedule.durations[position], note))
        legs = [leg for position in range(len(order)) if (leg := self.leg_into(position, order))]
        return Outcome(stops, legs, skipped, leg_from_anchor=self.anchor is not None)
