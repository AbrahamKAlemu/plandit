"""What a group plan and an edit to it may be (brief GE-1, GE-6; LIM-2 to LIM-9 in the test plan).

One member's malformed plan would stop every member's app from decoding the group (N-4), so the
server checks the parts of the app's `DayPlan` encoding that decoding needs, plus the limits. It
doesn't check what's inside each stop or leg: the app owns that shape.
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
# How far ahead a group plan's day may be, in New York days (settings.TIME_ZONE).
MAX_DAYS_AHEAD = 366
# An edit names what it did (`kind`, the app's own words, such as "remove" or "setTime") and which
# stops it touched; the server only stores them for the 409's "who changed what".
_EDIT_KIND = re.compile(r"\A[A-Za-z]{1,16}\Z")
_ISO_DATE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")

STOPS_LIMIT = f"A group plan has at most {MAX_STOPS} stops."
DAY_RANGE = "Use a day from today to a year from now."


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
    if parse_uuid(value.get("id")) is None:
        raise invalid("`id` must be a UUID.")
    for key in ("date", "budget"):
        if not is_number(value.get(key)):
            raise invalid(f"`{key}` must be a number.")
    if not isinstance(value.get("title"), str):
        raise invalid("`title` must be text.")
    if not isinstance(value.get("legs"), list):
        raise invalid("`legs` must be a list.")
    stops = value.get("stops")
    if not isinstance(stops, list):
        raise invalid("`stops` must be a list.")
    if len(stops) > MAX_STOPS:
        raise invalid(STOPS_LIMIT)
    seen = set()
    for stop in stops:
        stop_id = parse_uuid(stop.get("id")) if isinstance(stop, dict) else None
        if stop_id is None:
            raise invalid("Every stop needs a UUID `id`.")
        if stop_id in seen:
            raise invalid("Stop ids must be unique.")
        seen.add(stop_id)
    if _has_null_character(value):
        raise invalid("Text can't contain a null character.")
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
    parsed = [parse_uuid(stop_id) for stop_id in stop_ids] if isinstance(stop_ids, list) else None
    if parsed is None or len(parsed) > MAX_STOPS or None in parsed:
        raise ValidationError({"edit": [f"`stopIds` must be a list of at most {MAX_STOPS} UUIDs."]})
    return base, edit_id, kind, [str(stop_id).upper() for stop_id in parsed]


def _has_null_character(value) -> bool:
    """Postgres can't store U+0000 in jsonb. Walked without recursion: the parser accepts nesting
    deeper than Python's recursion limit."""
    pending = [value]
    while pending:
        item = pending.pop()
        if isinstance(item, str):
            if "\x00" in item:
                return True
        elif isinstance(item, dict):
            for key, child in item.items():
                if "\x00" in key:
                    return True
                pending.append(child)
        elif isinstance(item, list):
            pending.extend(item)
    return False
