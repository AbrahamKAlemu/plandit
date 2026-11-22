"""What a group plan and an edit to it may be (brief GE-1, GE-6; LIM-2 to LIM-9 in the test plan).

One member's malformed plan would stop every member's app from decoding the group (N-4), so the
server checks the parts of the app's `DayPlan` encoding that decoding needs, plus the limits: the
keys the Codable types decode with no default (ios/Plandit/Models/DayPlan.swift), ids in the one
form Swift's UUID reads, and how deep the JSON nests. It doesn't check the values inside each stop
or leg beyond that: the app owns that shape.
"""

import json
import re
import uuid
from datetime import date, timedelta

from django.utils import timezone
from rest_framework.exceptions import ValidationError

# Brief GE-1: a group plan's compact UTF-8 JSON, measured as plandit.core.views measures snapshots.
PLAN_MAX_BYTES = 65_536
# Refuse to parse a request body larger than this. The app's encoder writes "/" as "\/" and may
# escape other characters, so the body can be a few times the plan's compact size.
MAX_REQUEST_BYTES = 262_144
MAX_STOPS = 20
# How deep a plan's JSON may nest, counting the plan object as level 1.
MAX_DEPTH = 32
# How far ahead a group plan's day may be, in New York days (settings.TIME_ZONE).
MAX_DAYS_AHEAD = 366
# An edit names what it did (`kind`, the app's own words, such as "remove" or "setTime") and which
# stops it touched; the server only stores them for the 409's "who changed what".
_EDIT_KIND = re.compile(r"\A[A-Za-z]{1,16}\Z")
_ISO_DATE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")
# The only form Swift's UUID decodes, in either case. Python's UUID() also reads braces, a
# "urn:uuid:" prefix and bare hex, which would break decoding on every member's phone.
_CANONICAL_UUID = re.compile(r"\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z")
# The keys `PlanStop` and `TravelLeg` decode with no default. Optional ones (a stop's `note`,
# `sourcePostID`, `costItems`, `costIsCustom`; a leg's `cost`, `detail`, `isChosen`) aren't required.
STOP_KEYS = ("id", "place", "start", "durationMinutes", "estimatedCost", "status")
LEG_KEYS = ("id", "fromStopID", "toStopID", "mode", "minutes", "miles")

STOPS_LIMIT = f"A group plan has at most {MAX_STOPS} stops."
DAY_RANGE = "Use a day from today to a year from now."
TOO_DEEP = f"Can't be nested more than {MAX_DEPTH} levels deep."
NULL_CHARACTER = "Text can't contain a null character."


def _listed(keys) -> str:
    quoted = [f"`{key}`" for key in keys]
    return f"{', '.join(quoted[:-1])} and {quoted[-1]}"


STOP_NEEDS = f"Every stop needs {_listed(STOP_KEYS)}."
LEG_NEEDS = f"Every leg needs {_listed(LEG_KEYS)}."


class PlanTooLarge(Exception):
    def __init__(self, size: int):
        super().__init__(size)
        self.size = size


def parse_uuid(value) -> uuid.UUID | None:
    """A UUID in any case (Swift encodes them in upper case), or None."""
    if not isinstance(value, str):
        return None
    try:
        return uuid.UUID(value)
    except ValueError:
        return None


def parse_canonical_uuid(value) -> uuid.UUID | None:
    """A UUID written as 8-4-4-4-12 hex digits, in any case, or None. For ids stored in a plan or an
    edit, which every member's app decodes."""
    if not isinstance(value, str) or not _CANONICAL_UUID.match(value):
        return None
    return uuid.UUID(value)


def is_number(value) -> bool:
    """A JSON number. A bool is not one, although Python counts it as an int."""
    return isinstance(value, int | float) and not isinstance(value, bool)


def is_whole_number(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def parse_day(value) -> date:
    """`YYYY-MM-DD`, from today to MAX_DAYS_AHEAD days ahead in New York time."""
    if not isinstance(value, str) or not _ISO_DATE.match(value):
        raise ValidationError({"date": ["Use a date like 2026-11-28."]})
    try:
        day = date.fromisoformat(value)
    except ValueError as exc:
        raise ValidationError({"date": ["Use a date like 2026-11-28."]}) from exc
    today = timezone.localdate()
    if not today <= day <= today + timedelta(days=MAX_DAYS_AHEAD):
        raise ValidationError({"date": [DAY_RANGE]})
    return day


def parse_plan(value) -> dict:
    """The plan as the app encoded it, checked and unchanged. Raises ValidationError for a shape the
    app can't decode and PlanTooLarge over PLAN_MAX_BYTES."""

    def invalid(message: str):
        return ValidationError({"plan": [message]})

    if not isinstance(value, dict):
        raise invalid("Must be a JSON object.")
    problem = _tree_problem(value)
    if problem is not None:
        raise invalid(problem)
    if parse_canonical_uuid(value.get("id")) is None:
        raise invalid("`id` must be a UUID in its 36-character form.")
    for key in ("date", "budget"):
        if not is_number(value.get(key)):
            raise invalid(f"`{key}` must be a number.")
    if not isinstance(value.get("title"), str):
        raise invalid("`title` must be text.")
    legs = value.get("legs")
    if not isinstance(legs, list):
        raise invalid("`legs` must be a list.")
    if not all(_has_keys(leg, LEG_KEYS) for leg in legs):
        raise invalid(LEG_NEEDS)
    stops = value.get("stops")
    if not isinstance(stops, list):
        raise invalid("`stops` must be a list.")
    if len(stops) > MAX_STOPS:
        raise invalid(STOPS_LIMIT)
    if not all(_has_keys(stop, STOP_KEYS) for stop in stops):
        raise invalid(STOP_NEEDS)
    seen = set()
    for stop in stops:
        stop_id = parse_canonical_uuid(stop["id"])
        if stop_id is None:
            raise invalid("Every stop needs a UUID `id` in its 36-character form.")
        if stop_id in seen:
            raise invalid("Stop ids must be unique.")
        seen.add(stop_id)
    if "extras" in value and not isinstance(value["extras"], list):
        raise invalid("`extras` must be a list.")
    try:
        size = len(json.dumps(value, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8"))
    except (TypeError, ValueError, RecursionError) as exc:
        raise invalid("Must be plain JSON.") from exc
    if size > PLAN_MAX_BYTES:
        raise PlanTooLarge(size)
    return value


def parse_edit(body: dict) -> tuple[int, uuid.UUID, str, list[str]]:
    """`baseVersion`, `editId` and `edit: {kind, stopIds}` from a PUT body (MF-B, MF-C)."""
    base = body.get("baseVersion")
    if not is_whole_number(base) or base < 1:
        raise ValidationError({"baseVersion": ["Must be a whole number from 1."]})
    edit_id = parse_uuid(body.get("editId"))
    if edit_id is None:
        raise ValidationError({"editId": ["Must be a UUID."]})
    edit = body.get("edit")
    if not isinstance(edit, dict):
        raise ValidationError({"edit": ["Must be a JSON object with `kind` and `stopIds`."]})
    kind = edit.get("kind")
    if not isinstance(kind, str) or not _EDIT_KIND.match(kind):
        raise ValidationError({"edit": ["`kind` must be 1 to 16 letters."]})
    stop_ids = edit.get("stopIds")
    parsed = [parse_canonical_uuid(stop_id) for stop_id in stop_ids] if isinstance(stop_ids, list) else None
    if parsed is None or len(parsed) > MAX_STOPS or None in parsed:
        raise ValidationError(
            {"edit": [f"`stopIds` must be a list of at most {MAX_STOPS} UUIDs in their 36-character form."]}
        )
    return base, edit_id, kind, [str(stop_id).upper() for stop_id in parsed]


def _has_keys(item, keys) -> bool:
    """An object with each of `keys` set: a null fails Swift's `decode` just as a missing key does."""
    return isinstance(item, dict) and all(item.get(key) is not None for key in keys)


def _tree_problem(value) -> str | None:
    """Nesting deeper than MAX_DEPTH, or U+0000 anywhere (Postgres can't store it in jsonb).
    Walked without recursion: the parser accepts nesting deeper than Python's recursion limit."""
    pending = [(value, 1)]
    while pending:
        item, depth = pending.pop()
        if isinstance(item, str):
            if "\x00" in item:
                return NULL_CHARACTER
        elif isinstance(item, dict | list):
            if depth > MAX_DEPTH:
                return TOO_DEEP
            if isinstance(item, dict):
                if any("\x00" in key for key in item):
                    return NULL_CHARACTER
                pending.extend((child, depth + 1) for child in item.values())
            else:
                pending.extend((child, depth + 1) for child in item)
    return None
