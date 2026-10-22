import uuid

from django.db import models


class PlaceCategory(models.TextChoices):
    FOOD = "food", "Food"
    COFFEE = "coffee", "Coffee"
    ACTIVITY = "activity", "Activity"
    OUTDOORS = "outdoors", "Outdoors"
    CULTURE = "culture", "Culture"
    NIGHTLIFE = "nightlife", "Nightlife"
    SHOPPING = "shopping", "Shopping"


class Place(models.Model):
    """A pinnable place. Shared across users; created by extraction, seeding, or admins."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(max_length=160)
    category = models.CharField(max_length=20, choices=PlaceCategory.choices)
    neighborhood = models.CharField(max_length=120, blank=True)
    address = models.CharField(max_length=240, blank=True)
    latitude = models.FloatField()
    longitude = models.FloatField()
    hours = models.CharField(max_length=80, blank=True, null=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ["name"]
        constraints = [models.UniqueConstraint(fields=["name", "address"], name="place_unique_name_address")]
        indexes = [models.Index(fields=["category"]), models.Index(fields=["neighborhood"])]

    def __str__(self) -> str:
        return self.name
