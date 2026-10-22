from rest_framework import serializers

from plandit.places.models import Place
from plandit.places.serializers import PlaceSerializer

from .models import ExtractionStatus, SavedPost


class SavedPostSerializer(serializers.ModelSerializer):
    place = PlaceSerializer(read_only=True)
    place_id = serializers.PrimaryKeyRelatedField(
        queryset=Place.objects.all(), source="place", write_only=True, required=False, allow_null=True
    )
    is_mappable = serializers.BooleanField(read_only=True)

    class Meta:
        model = SavedPost
        fields = [
            "id",
            "url",
            "platform",
            "creator_handle",
            "caption",
            "thumbnail_url",
            "saved_at",
            "status",
            "place",
            "place_id",
            "estimated_cost",
            "tags",
            "failure_reason",
            "is_mappable",
        ]
        read_only_fields = [
            "id",
            "url",
            "platform",
            "creator_handle",
            "thumbnail_url",
            "saved_at",
            "status",
            "failure_reason",
        ]

    def update(self, instance, validated_data):
        # A user picking the place by hand resolves "needs review" / "failed".
        if validated_data.get("place") is not None:
            validated_data["status"] = ExtractionStatus.READY
            validated_data["failure_reason"] = ""
        return super().update(instance, validated_data)


class SavedPostCreateSerializer(serializers.Serializer):
    url = serializers.URLField(max_length=1000)
    shared_text = serializers.CharField(required=False, allow_blank=True, max_length=5000)
