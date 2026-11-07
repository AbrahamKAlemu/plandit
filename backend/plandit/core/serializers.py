from datetime import timedelta

from django.utils import timezone
from rest_framework import serializers

from .models import ActivityEventName, Profile

EVENT_MAX_AGE = timedelta(days=7)


class ProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = Profile
        fields = ["id", "email", "name", "school", "home_base", "default_budget", "travel_modes", "created_at"]
        read_only_fields = ["id", "email", "created_at"]

    def update(self, instance, validated_data):
        """Write only the changed columns. A plain `save()` falls through to INSERT when the
        UPDATE matches no row, which would resurrect a profile deleted a moment earlier."""
        for field, value in validated_data.items():
            setattr(instance, field, value)
        instance.save(update_fields=[*validated_data, "updated_at"])
        return instance


class ActivityEventSerializer(serializers.Serializer):
    """POST /api/me/events/ body. `occurred_at` is clamped to the last 7 days, never rejected."""

    name = serializers.ChoiceField(choices=ActivityEventName.choices)
    occurred_at = serializers.DateTimeField(required=False)

    def validate(self, attrs):
        now = timezone.now()
        occurred_at = attrs.get("occurred_at") or now
        attrs["occurred_at"] = min(max(occurred_at, now - EVENT_MAX_AGE), now)
        return attrs
