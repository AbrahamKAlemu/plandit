from rest_framework import serializers

from .models import Place


class PlaceSerializer(serializers.ModelSerializer):
    class Meta:
        model = Place
        fields = ["id", "name", "category", "neighborhood", "address", "latitude", "longitude", "hours"]
        read_only_fields = fields
