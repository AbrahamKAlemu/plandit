from rest_framework import serializers

from .models import Profile


class ProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = Profile
        fields = ["id", "email", "name", "school", "home_base", "default_budget", "travel_modes", "created_at"]
        read_only_fields = ["id", "email", "created_at"]
