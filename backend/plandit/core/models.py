import uuid

from django.db import models


class ProfileManager(models.Manager):
    def get_or_create_from_claims(self, claims: dict) -> "Profile":
        """Find the profile for a verified Supabase access token, creating it on first sight."""
        user_id = uuid.UUID(str(claims["sub"]))
        metadata = claims.get("user_metadata") or {}
        email = claims.get("email") or ""
        profile, created = self.get_or_create(
            id=user_id,
            defaults={"email": email, "name": metadata.get("full_name") or metadata.get("name") or ""},
        )
        if not created and email and profile.email != email:
            profile.email = email
            profile.save(update_fields=["email", "updated_at"])
        return profile


class Profile(models.Model):
    """One row per Supabase Auth user. The primary key is the Supabase `auth.users.id`."""

    id = models.UUIDField(primary_key=True, editable=False)
    email = models.EmailField(blank=True)
    name = models.CharField(max_length=120, blank=True)
    school = models.CharField(max_length=120, blank=True)
    home_base = models.CharField(max_length=120, blank=True)
    default_budget = models.DecimalField(max_digits=8, decimal_places=2, default=60)
    travel_modes = models.CharField(max_length=60, blank=True, default="Walk + subway")
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    objects = ProfileManager()

    # Lets DRF's IsAuthenticated treat a Profile as a logged-in user without django.contrib.auth.
    is_authenticated = True
    is_anonymous = False
    is_active = True

    class Meta:
        ordering = ["created_at"]

    def __str__(self) -> str:
        return self.name or self.email or str(self.id)
