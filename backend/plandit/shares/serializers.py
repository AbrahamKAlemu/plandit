from rest_framework import serializers

MAX_STOPS = 30


class SharedStopSerializer(serializers.Serializer):
    name = serializers.CharField(max_length=120)
    place = serializers.CharField(max_length=120, required=False, allow_blank=True, default="")
    address = serializers.CharField(max_length=200, required=False, allow_blank=True, default="")
    timeText = serializers.CharField(max_length=40)
    durationText = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")
    costText = serializers.CharField(max_length=40, required=False, allow_blank=True, default="")
    latitude = serializers.FloatField(min_value=-90, max_value=90, required=False, allow_null=True, default=None)
    longitude = serializers.FloatField(min_value=-180, max_value=180, required=False, allow_null=True, default=None)


class SharedLegSerializer(serializers.Serializer):
    text = serializers.CharField(max_length=120)


class SharedPlanSerializer(serializers.Serializer):
    """What the app sends to share a plan. Every text is display-ready: the server doesn't format
    times or money, so the page shows them exactly as the owner's phone did."""

    planId = serializers.UUIDField()
    title = serializers.CharField(max_length=120)
    dateText = serializers.CharField(max_length=60)
    timeText = serializers.CharField(max_length=60, required=False, allow_blank=True, default="")
    note = serializers.CharField(max_length=280, required=False, allow_blank=True, default="")
    costText = serializers.CharField(max_length=160, required=False, allow_blank=True, default="")
    stops = SharedStopSerializer(many=True)
    legs = SharedLegSerializer(many=True, required=False, default=list)

    def validate_stops(self, stops):
        if not stops:
            raise serializers.ValidationError("A shared plan needs at least one stop.")
        if len(stops) > MAX_STOPS:
            raise serializers.ValidationError(f"At most {MAX_STOPS} stops.")
        return stops

    def validate(self, attrs):
        if len(attrs["legs"]) > max(0, len(attrs["stops"]) - 1):
            raise serializers.ValidationError({"legs": "At most one trip between each pair of stops."})
        return attrs
