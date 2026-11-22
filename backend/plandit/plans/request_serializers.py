"""What the app sends to create a friends' input link (group plans, mode 2; brief GI-1)."""

import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from django.utils import timezone
from rest_framework import serializers

from plandit.shares.serializers import IsoDateField, SharedAlternateSerializer

MIN_PLACES = 2
MAX_PLACES = 10
MAX_DAYS_AHEAD = 14
MIN_WINDOW_MINUTES = 60

_HOUR_MINUTE = re.compile(r"\A(?:[01]\d|2[0-3]):[0-5]\d\Z")
_UTC_OFFSET = re.compile(r"(?:Z|[+-]\d{2}:?\d{2})\Z")
# IANA names: Area/Location, letters, digits, _ + -. Checked before the name reaches ZoneInfo.
_TIME_ZONE = re.compile(r"\A[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+){0,2}\Z")


class RequestPlaceSerializer(SharedAlternateSerializer):
    """A place friends can star (brief GI-2): one of the organizer's saves, chosen on the phone.
    Same shape as a shared plan's alternate: `{id, name, neighborhood, kind, costText}`, with the
    cost in dollars as the app shows it ("$6", "Free")."""


class HourMinuteField(serializers.TimeField):
    """A local time written HH:MM, 00:00 to 23:59, and written back the same way."""

    def __init__(self, **kwargs):
        super().__init__(format="%H:%M", **kwargs)

    def to_internal_value(self, value):
        if not isinstance(value, str) or not _HOUR_MINUTE.match(value):
            self.fail("invalid", format="HH:MM")
        return super().to_internal_value(value)


class MomentField(serializers.DateTimeField):
    """An ISO 8601 date and time with Z or a UTC offset: a moment, never a local time to guess at."""

    def to_internal_value(self, value):
        if not isinstance(value, str) or not _UTC_OFFSET.search(value):
            self.fail("invalid", format="YYYY-MM-DDThh:mm:ss with Z or a UTC offset")
        return super().to_internal_value(value)


class TimeZoneField(serializers.CharField):
    """An IANA time zone name, such as America/New_York."""

    default_error_messages = {"unknown": "Not a known time zone."}

    def __init__(self, **kwargs):
        super().__init__(max_length=64, **kwargs)

    def to_internal_value(self, data):
        name = super().to_internal_value(data)
        if not _TIME_ZONE.match(name):
            self.fail("unknown")
        try:
            ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            self.fail("unknown")
        return name


class GroupRequestSerializer(serializers.Serializer):
    """POST /api/plan-requests/ (brief GI-1): 2 to 10 places, a day from today to 14 days out, a
    time range of at least 1 hour on it, and a deadline for answers. "Today" is the request's own
    time zone's, and the deadline is a moment from now to the end of the range on the day."""

    places = RequestPlaceSerializer(many=True)
    day = IsoDateField()
    windowStart = HourMinuteField()
    windowEnd = HourMinuteField()
    timeZone = TimeZoneField()
    answersBy = MomentField()

    def validate_places(self, places):
        if not MIN_PLACES <= len(places) <= MAX_PLACES:
            raise serializers.ValidationError(f"From {MIN_PLACES} to {MAX_PLACES} places.")
        ids = [place["id"].lower() for place in places]
        if len(set(ids)) != len(ids):
            raise serializers.ValidationError("Each place once.")
        return places

    def validate(self, attrs):
        zone = ZoneInfo(attrs["timeZone"])
        today = timezone.now().astimezone(zone).date()
        if not today <= attrs["day"] <= today + timedelta(days=MAX_DAYS_AHEAD):
            raise serializers.ValidationError({"day": f"From today to {MAX_DAYS_AHEAD} days ahead."})
        start = datetime.combine(attrs["day"], attrs["windowStart"], tzinfo=zone)
        end = datetime.combine(attrs["day"], attrs["windowEnd"], tzinfo=zone)
        if end - start < timedelta(minutes=MIN_WINDOW_MINUTES):
            raise serializers.ValidationError({"windowEnd": "At least 1 hour after windowStart."})
        if not timezone.now() < attrs["answersBy"] <= end:
            raise serializers.ValidationError({"answersBy": "After now and no later than the end of the range."})
        return attrs
