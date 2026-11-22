import re
from datetime import timedelta

from django.utils import timezone
from rest_framework import serializers

MAX_STOPS = 30
MAX_ALTERNATES = 2
# How far ahead a plan's `date` may be. It sets when friends' answers are deleted (30 days after
# it, brief GS-5), so it can't be pushed out indefinitely.
MAX_DAYS_AHEAD = 366

# The app's ids are Swift UUIDs, which encode in upper case. They're kept exactly as sent, so the
# app finds its own ids again in the answers it reads back.
_UUID = re.compile(r"\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\Z")
_ISO_DATE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")


class AppIdField(serializers.CharField):
    """A UUID string, kept as sent."""

    default_error_messages = {"invalid_id": "Must be a UUID."}

    def __init__(self, **kwargs):
        super().__init__(max_length=36, **kwargs)

    def to_internal_value(self, data):
        if not isinstance(data, str) or not _UUID.match(data):
            self.fail("invalid_id")
        return data


class StrictBooleanField(serializers.BooleanField):
    """JSON true or false only: not "yes", 1 or null."""

    def to_internal_value(self, data):
        if isinstance(data, bool):
            return data
        self.fail("invalid", input=data)


class IsoDateField(serializers.DateField):
    """YYYY-MM-DD only: not a datetime, a week date or the compact form."""

    def to_internal_value(self, value):
        if not isinstance(value, str) or not _ISO_DATE.match(value):
            self.fail("invalid", format="YYYY-MM-DD")
        return super().to_internal_value(value)


class SharedAlternateSerializer(serializers.Serializer):
    """A place the organizer offers instead of a stop (brief GV-2, GV-9): one of their own saves,
    chosen on the phone, shown as "<name> instead"."""

    id = AppIdField()
    name = serializers.CharField(max_length=120)
    neighborhood = serializers.CharField(max_length=80, required=False, allow_blank=True, default="")
    kind = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")
    costText = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")


class SharedStopSerializer(serializers.Serializer):
    id = AppIdField(required=False)
    name = serializers.CharField(max_length=120)
    place = serializers.CharField(max_length=120, required=False, allow_blank=True, default="")
    address = serializers.CharField(max_length=200, required=False, allow_blank=True, default="")
    timeText = serializers.CharField(max_length=40)
    durationText = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")
    costText = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")
    latitude = serializers.FloatField(min_value=-90, max_value=90, required=False, allow_null=True, default=None)
    longitude = serializers.FloatField(min_value=-180, max_value=180, required=False, allow_null=True, default=None)
    alternates = SharedAlternateSerializer(many=True, required=False)

    def validate_alternates(self, alternates):
        if len(alternates) > MAX_ALTERNATES:
            raise serializers.ValidationError(f"At most {MAX_ALTERNATES} alternates per stop.")
        ids = [alternate["id"].lower() for alternate in alternates]
        if len(set(ids)) != len(ids):
            raise serializers.ValidationError("Each alternate once.")
        return alternates

    def validate(self, attrs):
        if attrs.get("alternates") and "id" not in attrs:
            raise serializers.ValidationError({"alternates": "Alternates need the stop's id."})
        return attrs


class SharedLegSerializer(serializers.Serializer):
    text = serializers.CharField(max_length=120)


class SharedPlanSerializer(serializers.Serializer):
    """What the app sends to share a plan. Every text is display-ready: the server doesn't format
    times or money, so the page shows them exactly as the owner's phone did.

    Group plans (mode 1) add optional fields, which today's app doesn't send: `answers` turns on
    the answer form on the page, `date` (needed with it) is the plan's day, and stops may carry an
    `id` and up to 2 `alternates`, which friends can pick from with "I'd swap this"."""

    planId = serializers.UUIDField()
    title = serializers.CharField(max_length=120)
    dateText = serializers.CharField(max_length=60)
    timeText = serializers.CharField(max_length=60, required=False, allow_blank=True, default="")
    note = serializers.CharField(max_length=280, required=False, allow_blank=True, default="")
    costText = serializers.CharField(max_length=160, required=False, allow_blank=True, default="")
    stops = SharedStopSerializer(many=True)
    legs = SharedLegSerializer(many=True, required=False, default=list)
    answers = StrictBooleanField(required=False)
    date = IsoDateField(required=False)

    def validate_stops(self, stops):
        if not stops:
            raise serializers.ValidationError("A shared plan needs at least one stop.")
        if len(stops) > MAX_STOPS:
            raise serializers.ValidationError(f"At most {MAX_STOPS} stops.")
        ids = [stop["id"].lower() for stop in stops if "id" in stop]
        if len(set(ids)) != len(ids):
            raise serializers.ValidationError("Each stop id once.")
        return stops

    def validate_date(self, value):
        if value > timezone.localdate() + timedelta(days=MAX_DAYS_AHEAD):
            raise serializers.ValidationError("At most a year ahead.")
        return value

    def validate(self, attrs):
        if len(attrs["legs"]) > max(0, len(attrs["stops"]) - 1):
            raise serializers.ValidationError({"legs": "At most one trip between each pair of stops."})
        if attrs.get("answers") and "date" not in attrs:
            raise serializers.ValidationError({"date": "Needed when answers is true."})
        return attrs
