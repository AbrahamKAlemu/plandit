from rest_framework import serializers

from plandit.places.serializers import PlaceSerializer

from .models import DayPlan, PlanStop, TravelLeg


class TravelLegSerializer(serializers.ModelSerializer):
    class Meta:
        model = TravelLeg
        fields = ["id", "from_stop", "to_stop", "mode", "minutes", "miles", "cost", "detail"]
        read_only_fields = fields


class PlanStopSerializer(serializers.ModelSerializer):
    place = PlaceSerializer(read_only=True)
    end = serializers.DateTimeField(read_only=True)

    class Meta:
        model = PlanStop
        fields = [
            "id",
            "position",
            "place",
            "start",
            "end",
            "duration_minutes",
            "estimated_cost",
            "note",
            "source_post",
            "status",
        ]
        read_only_fields = ["id", "position", "place", "end", "source_post"]


class DayPlanSerializer(serializers.ModelSerializer):
    stops = PlanStopSerializer(many=True, read_only=True)
    legs = TravelLegSerializer(many=True, read_only=True)
    total_cost = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)
    walking_miles = serializers.FloatField(read_only=True)

    class Meta:
        model = DayPlan
        fields = [
            "id",
            "date",
            "title",
            "budget",
            "stops",
            "legs",
            "total_cost",
            "walking_miles",
            "created_at",
            "updated_at",
        ]
        read_only_fields = ["id", "created_at", "updated_at"]


class DayPlanSummarySerializer(serializers.ModelSerializer):
    stop_count = serializers.SerializerMethodField()
    total_cost = serializers.DecimalField(max_digits=10, decimal_places=2, read_only=True)

    class Meta:
        model = DayPlan
        fields = ["id", "date", "title", "budget", "stop_count", "total_cost"]

    def get_stop_count(self, plan) -> int:
        return len(plan.stops.all())


class DayPlanWriteSerializer(serializers.ModelSerializer):
    class Meta:
        model = DayPlan
        fields = ["date", "title", "budget"]
        extra_kwargs = {"date": {"required": False}, "title": {"required": False}, "budget": {"required": False}}


class AddStopSerializer(serializers.Serializer):
    saved_post_id = serializers.UUIDField(required=False)
    place_id = serializers.UUIDField(required=False)
    start = serializers.DateTimeField(required=False)
    duration_minutes = serializers.IntegerField(required=False, min_value=5, max_value=24 * 60)
    estimated_cost = serializers.DecimalField(max_digits=8, decimal_places=2, required=False, min_value=0)
    note = serializers.CharField(required=False, allow_blank=True, max_length=500)

    def validate(self, attrs):
        if ("saved_post_id" in attrs) == ("place_id" in attrs):
            raise serializers.ValidationError("Send exactly one of saved_post_id or place_id.")
        return attrs


class ReorderSerializer(serializers.Serializer):
    stop_ids = serializers.ListField(child=serializers.UUIDField(), allow_empty=False)
